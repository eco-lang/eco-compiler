# Move Type Table Construction to Monomorphization

## Overview

**Goal**: Move type-table construction from the MLIR backend into the monomorphization phase. The MLIR backend will become a pure serializer of a pre-built type graph.

**Current State**:
- MLIR's `TypeRegistry` in `Context` discovers and registers types during code generation
- `getOrCreateTypeIdForMonoType` dynamically assigns type IDs as types are encountered
- Constructor layouts are registered via `registerCtorLayout` during code generation
- `generateTypeTable` walks `ctx.typeRegistry` to build the serialized `eco.type_table` op

**Problem**:
- Backend-centric design only *reconstructs* information from `Mono`
- Easy to miss pieces (e.g., unused constructors) even though monomorphization had them
- Violates the principle that monomorphization should produce complete type information

**After**:
- Monomorphization builds a complete `MonoTypeGraph` with all types and constructors
- MLIR backend only serializes the pre-built graph
- All constructors are included, even unused ones (comprehensive type graph)

---

## Decision Summary

| Question | Decision |
|----------|----------|
| Union data access | Pass simple `UnionEnv` externally; build `UnionRegistry` internally in monomorphization |
| Generic ctor instantiation | Use existing substitution logic in Monomorphize.elm |
| Non-allocated types | Include all types (comprehensive type graph) |
| Data structure | `Dict MonoType MonoTypeId` + reversed Lists with `nextIndex` counters |
| Polymorphic types | Keep `TKPolymorphic` with constraint (same as current) |
| Kernel types | Register them in the type graph |

---

## Phase 1: Define Type Graph Data Structures

### Step 1.1: Create `Compiler/AST/MonoTypeGraph.elm` (NEW FILE)

```elm
module Compiler.AST.MonoTypeGraph exposing
    ( MonoTypeGraph
    , MonoTypeId
    , TypeDescriptor(..)
    , FieldDescriptor
    , CtorDescriptor
    , PrimKind(..)
    , TypeGraphBuilder
    , emptyBuilder
    , freeze
    , lookupTypeId
    )

import Compiler.AST.Monomorphized as Mono
import Dict exposing (Dict)

type alias MonoTypeId = Int

-- ============================================================================
-- FROZEN TYPE GRAPH (immutable, final output)
-- ============================================================================

type alias MonoTypeGraph =
    { typeIds : Dict (List String) MonoTypeId   -- comparable MonoType -> TypeId
    , types : List TypeDescriptor               -- ordered by TypeId
    , fields : List FieldDescriptor             -- flattened field array
    , ctors : List CtorDescriptor               -- flattened ctor array
    , funcArgs : List MonoTypeId                -- flattened function arg TypeIds
    , strings : List String                     -- ordered string table
    }

type TypeDescriptor
    = TDPrimitive { typeId : MonoTypeId, primKind : PrimKind }
    | TDList { typeId : MonoTypeId, elemTypeId : MonoTypeId }
    | TDTuple { typeId : MonoTypeId, firstField : Int, fieldCount : Int }
    | TDRecord { typeId : MonoTypeId, firstField : Int, fieldCount : Int }
    | TDCustom { typeId : MonoTypeId, firstCtor : Int, ctorCount : Int }
    | TDFunction { typeId : MonoTypeId, firstArg : Int, argCount : Int, resultTypeId : MonoTypeId }
    | TDPolymorphic { typeId : MonoTypeId, constraint : Mono.Constraint }

type PrimKind
    = PKInt
    | PKFloat
    | PKChar
    | PKBool
    | PKString
    | PKUnit

type alias FieldDescriptor =
    { nameIndex : Int
    , typeId : MonoTypeId
    }

type alias CtorDescriptor =
    { ctorId : Int
    , nameIndex : Int
    , firstField : Int
    , fieldCount : Int
    }

-- ============================================================================
-- BUILDER STATE (mutable during construction)
-- ============================================================================

type alias TypeGraphBuilder =
    { nextTypeId : Int
    , typeIds : Dict (List String) MonoTypeId
    , types : List TypeDescriptor               -- reversed, will flip at freeze
    , fields : List FieldDescriptor             -- reversed
    , ctors : List CtorDescriptor               -- reversed
    , funcArgs : List MonoTypeId                -- reversed
    , strings : Dict String Int                 -- string -> index
    , nextStringIndex : Int
    , nextFieldIndex : Int
    , nextCtorIndex : Int
    , nextFuncArgIndex : Int
    }

emptyBuilder : TypeGraphBuilder
emptyBuilder =
    { nextTypeId = 0
    , typeIds = Dict.empty
    , types = []
    , fields = []
    , ctors = []
    , funcArgs = []
    , strings = Dict.empty
    , nextStringIndex = 0
    , nextFieldIndex = 0
    , nextCtorIndex = 0
    , nextFuncArgIndex = 0
    }

freeze : TypeGraphBuilder -> MonoTypeGraph
freeze builder =
    { typeIds = builder.typeIds
    , types = List.reverse builder.types
    , fields = List.reverse builder.fields
    , ctors = List.reverse builder.ctors
    , funcArgs = List.reverse builder.funcArgs
    , strings =
        builder.strings
            |> Dict.toList
            |> List.sortBy Tuple.second
            |> List.map Tuple.first
    }

lookupTypeId : Mono.MonoType -> MonoTypeGraph -> Maybe MonoTypeId
lookupTypeId monoType graph =
    Dict.get (Mono.toComparableMonoType monoType) graph.typeIds
```

### Step 1.2: Extend `Mono.MonoGraph` in `Compiler/AST/Monomorphized.elm`

Add `typeGraph` field and `UnionEnv` type:

```elm
-- Add import
import Compiler.AST.MonoTypeGraph as MonoTypeGraph

-- Add UnionEnv type (external API for passing raw Can.Union data)
type alias UnionEnv =
    Dict (List String) (Dict String Name.Name Can.Union)
    -- IO.Canonical (comparable) -> typeName -> Can.Union

-- Extend MonoGraph
type MonoGraph
    = MonoGraph
        { nodes : Dict Int Int MonoNode
        , main : Maybe MainInfo
        , registry : SpecializationRegistry
        , typeGraph : MonoTypeGraph.MonoTypeGraph   -- NEW
        }
```

---

## Phase 2: Define Internal Union Registry in Monomorphize.elm

### Step 2.1: Add internal `UnionRegistry` types (NOT exported)

```elm
-- In Compiler/Generate/Monomorphize.elm (internal only)

type alias UnionRegistry =
    { byType : Dict (List String) UnionEntry
    , byCtor : Dict (List String) CtorEntry
    }

type alias UnionEntry =
    { home : IO.Canonical
    , typeName : Name.Name
    , union : Can.Union
    }

type alias CtorEntry =
    { home : IO.Canonical
    , typeName : Name.Name
    , ctorName : Name.Name
    , union : Can.Union
    , ctor : Can.Ctor
    }

emptyUnionRegistry : UnionRegistry
emptyUnionRegistry =
    { byType = Dict.empty
    , byCtor = Dict.empty
    }
```

### Step 2.2: Create `buildUnionRegistry` function

```elm
buildUnionRegistry : Mono.UnionEnv -> UnionRegistry
buildUnionRegistry unionEnv =
    Dict.foldl
        (\homeKey typeDict acc ->
            let
                home = IO.fromComparableCanonical homeKey
            in
            Dict.foldl
                (\_ ( typeName, canUnion ) innerAcc ->
                    let
                        unionEntry =
                            { home = home
                            , typeName = typeName
                            , union = canUnion
                            }

                        typeKey =
                            toComparableUnionKey home typeName

                        byType_ =
                            Dict.insert identity typeKey unionEntry innerAcc.byType

                        byCtor_ =
                            case canUnion of
                                Can.Union unionData ->
                                    List.foldl
                                        (\(Can.Ctor ctorData) ctorAcc ->
                                            let
                                                ctorEntry =
                                                    { home = home
                                                    , typeName = typeName
                                                    , ctorName = ctorData.name
                                                    , union = canUnion
                                                    , ctor = Can.Ctor ctorData
                                                    }
                                                ctorKey =
                                                    toComparableCtorKey home ctorData.name
                                            in
                                            Dict.insert identity ctorKey ctorEntry ctorAcc
                                        )
                                        innerAcc.byCtor
                                        unionData.alts
                    in
                    { byType = byType_, byCtor = byCtor_ }
                )
                acc
                typeDict
        )
        emptyUnionRegistry
        unionEnv
```

### Step 2.3: Add lookup helpers

```elm
lookupUnionByType : IO.Canonical -> Name.Name -> MonoState -> Maybe UnionEntry
lookupUnionByType home typeName state =
    Dict.get (toComparableUnionKey home typeName) state.unionRegistry.byType

lookupCtorByName : IO.Canonical -> Name.Name -> MonoState -> Maybe CtorEntry
lookupCtorByName home ctorName state =
    Dict.get (toComparableCtorKey home ctorName) state.unionRegistry.byCtor

-- Helper key functions
toComparableUnionKey : IO.Canonical -> Name.Name -> List String
toComparableCtorKey : IO.Canonical -> Name.Name -> List String
```

---

## Phase 3: Update Monomorphization State and Entry Point

### Step 3.1: Extend `MonoState`

```elm
type alias MonoState =
    { worklist : List WorkItem
    , nodes : Dict Int Int Mono.MonoNode
    , inProgress : EverySet Int Int
    , registry : Mono.SpecializationRegistry
    , lambdaCounter : Int
    , currentModule : IO.Canonical
    , toptNodes : Dict (List String) TOpt.Global TOpt.Node
    , currentGlobal : Maybe Mono.Global
    , unionRegistry : UnionRegistry                     -- NEW
    , typeGraphBuilder : MonoTypeGraph.TypeGraphBuilder -- NEW
    }
```

### Step 3.2: Update `monomorphize` signature and implementation

```elm
monomorphize : String -> TOpt.GlobalGraph -> Mono.UnionEnv -> Result String Mono.MonoGraph
monomorphize entryPointName (TOpt.GlobalGraph nodes _ _) unionEnv =
    let
        -- Build internal registry once at initialization
        unionRegistry =
            buildUnionRegistry unionEnv
    in
    case findEntryPoint entryPointName nodes of
        Nothing ->
            Err ("No " ++ entryPointName ++ " function found")

        Just ( mainGlobal, mainType ) ->
            monomorphizeFromEntry mainGlobal mainType nodes unionRegistry
```

### Step 3.3: Update `initState` to include new fields

```elm
initState : IO.Canonical -> Dict (List String) TOpt.Global TOpt.Node -> UnionRegistry -> MonoState
initState currentModule toptNodes unionRegistry =
    { worklist = []
    , nodes = EveryDict.empty compare
    , inProgress = EverySet.empty compare
    , registry = Mono.emptyRegistry
    , lambdaCounter = 0
    , currentModule = currentModule
    , toptNodes = toptNodes
    , currentGlobal = Nothing
    , unionRegistry = unionRegistry                    -- NEW
    , typeGraphBuilder = MonoTypeGraph.emptyBuilder    -- NEW
    }
```

---

## Phase 4: Register Types During Specialization

### Step 4.1: Create core `registerMonoType` function

```elm
registerMonoType : Mono.MonoType -> MonoState -> ( MonoTypeGraph.MonoTypeId, MonoState )
registerMonoType monoType state =
    let
        key = Mono.toComparableMonoType monoType
        builder = state.typeGraphBuilder
    in
    case Dict.get key builder.typeIds of
        Just typeId ->
            -- Already registered
            ( typeId, state )

        Nothing ->
            -- 1. First register any nested types (recursively)
            stateWithNested =
                registerNestedTypes monoType state

            -- 2. Allocate TypeId
            let
                builderAfterNested = stateWithNested.typeGraphBuilder
                typeId = builderAfterNested.nextTypeId
            in
            -- 3. Build descriptor and update builder
            let
                ( descriptor, builderWithDescriptor ) =
                    buildTypeDescriptor typeId monoType stateWithNested

                finalBuilder =
                    { builderWithDescriptor
                        | nextTypeId = typeId + 1
                        , typeIds = Dict.insert key typeId builderWithDescriptor.typeIds
                        , types = descriptor :: builderWithDescriptor.types
                    }
            in
            ( typeId, { stateWithNested | typeGraphBuilder = finalBuilder } )
```

### Step 4.2: Create `registerNestedTypes` function

```elm
registerNestedTypes : Mono.MonoType -> MonoState -> MonoState
registerNestedTypes monoType state =
    case monoType of
        Mono.MList elemType ->
            Tuple.second (registerMonoType elemType state)

        Mono.MTuple layout ->
            List.foldl
                (\( elemType, _ ) accState ->
                    Tuple.second (registerMonoType elemType accState)
                )
                state
                layout.elements

        Mono.MRecord layout ->
            List.foldl
                (\fieldInfo accState ->
                    Tuple.second (registerMonoType fieldInfo.monoType accState)
                )
                state
                layout.fields

        Mono.MCustom home typeName typeArgs ->
            -- Register type args AND all constructor field types
            let
                stateWithArgs =
                    List.foldl
                        (\argType accState ->
                            Tuple.second (registerMonoType argType accState)
                        )
                        state
                        typeArgs
            in
            registerCustomTypeCtorFields home typeName typeArgs stateWithArgs

        Mono.MFunction argTypes resultType ->
            let
                stateWithArgs =
                    List.foldl
                        (\argType accState ->
                            Tuple.second (registerMonoType argType accState)
                        )
                        state
                        argTypes
            in
            Tuple.second (registerMonoType resultType stateWithArgs)

        -- Primitives have no nested types
        _ ->
            state
```

### Step 4.3: Create `registerCustomTypeCtorFields` for ALL constructors

This is the key function that uses `UnionRegistry` to enumerate all constructors:

```elm
registerCustomTypeCtorFields : IO.Canonical -> Name.Name -> List Mono.MonoType -> MonoState -> MonoState
registerCustomTypeCtorFields home typeName typeArgs state =
    case lookupUnionByType home typeName state of
        Nothing ->
            -- Type not in registry (shouldn't happen for valid programs)
            state

        Just unionEntry ->
            case unionEntry.union of
                Can.Union unionData ->
                    let
                        -- Build substitution from union's type vars to concrete typeArgs
                        subst =
                            buildSubstitutionFromVars unionData.vars typeArgs
                    in
                    -- Register field types for ALL constructors
                    List.foldl
                        (\(Can.Ctor ctorData) accState ->
                            List.foldl
                                (\canFieldType innerState ->
                                    let
                                        monoFieldType =
                                            applySubst subst canFieldType
                                    in
                                    Tuple.second (registerMonoType monoFieldType innerState)
                                )
                                accState
                                ctorData.args
                        )
                        state
                        unionData.alts
```

### Step 4.4: Create `buildTypeDescriptor` for each type kind

```elm
buildTypeDescriptor : MonoTypeGraph.MonoTypeId -> Mono.MonoType -> MonoState -> ( MonoTypeGraph.TypeDescriptor, MonoTypeGraph.TypeGraphBuilder )
buildTypeDescriptor typeId monoType state =
    let
        builder = state.typeGraphBuilder
    in
    case monoType of
        Mono.MInt ->
            ( MonoTypeGraph.TDPrimitive { typeId = typeId, primKind = MonoTypeGraph.PKInt }
            , builder
            )

        Mono.MFloat ->
            ( MonoTypeGraph.TDPrimitive { typeId = typeId, primKind = MonoTypeGraph.PKFloat }
            , builder
            )

        -- ... other primitives ...

        Mono.MList elemType ->
            let
                elemTypeId =
                    lookupTypeIdOrFail elemType state
            in
            ( MonoTypeGraph.TDList { typeId = typeId, elemTypeId = elemTypeId }
            , builder
            )

        Mono.MTuple layout ->
            buildTupleDescriptor typeId layout state

        Mono.MRecord layout ->
            buildRecordDescriptor typeId layout state

        Mono.MCustom home typeName typeArgs ->
            buildCustomDescriptor typeId home typeName typeArgs state

        Mono.MFunction argTypes resultType ->
            buildFunctionDescriptor typeId argTypes resultType state

        Mono.MVar _ constraint ->
            ( MonoTypeGraph.TDPolymorphic { typeId = typeId, constraint = constraint }
            , builder
            )
```

### Step 4.5: Create `buildCustomDescriptor` using UnionRegistry

```elm
buildCustomDescriptor : MonoTypeGraph.MonoTypeId -> IO.Canonical -> Name.Name -> List Mono.MonoType -> MonoState -> ( MonoTypeGraph.TypeDescriptor, MonoTypeGraph.TypeGraphBuilder )
buildCustomDescriptor typeId home typeName typeArgs state =
    case lookupUnionByType home typeName state of
        Nothing ->
            -- Fallback: empty custom type (shouldn't happen)
            ( MonoTypeGraph.TDCustom { typeId = typeId, firstCtor = 0, ctorCount = 0 }
            , state.typeGraphBuilder
            )

        Just unionEntry ->
            case unionEntry.union of
                Can.Union unionData ->
                    let
                        builder = state.typeGraphBuilder
                        firstCtor = builder.nextCtorIndex

                        -- Build substitution for this instantiation
                        subst =
                            buildSubstitutionFromVars unionData.vars typeArgs

                        -- Add ALL constructors (not just used ones)
                        ( builderWithCtors, ctorCount ) =
                            List.foldl
                                (\ctor ( accBuilder, count ) ->
                                    let
                                        newBuilder =
                                            addCtorDescriptor subst ctor accBuilder state
                                    in
                                    ( newBuilder, count + 1 )
                                )
                                ( builder, 0 )
                                unionData.alts

                        descriptor =
                            MonoTypeGraph.TDCustom
                                { typeId = typeId
                                , firstCtor = firstCtor
                                , ctorCount = ctorCount
                                }
                    in
                    ( descriptor, builderWithCtors )
```

### Step 4.6: Create `addCtorDescriptor` helper

```elm
addCtorDescriptor : Substitution -> Can.Ctor -> MonoTypeGraph.TypeGraphBuilder -> MonoState -> MonoTypeGraph.TypeGraphBuilder
addCtorDescriptor subst (Can.Ctor ctorData) builder state =
    let
        -- Add ctor name to string table
        ( nameIndex, builderWithName ) =
            getOrCreateStringIndex (Name.toElmString ctorData.name) builder

        firstField = builderWithName.nextFieldIndex

        -- Add field descriptors
        ( builderWithFields, fieldCount ) =
            List.foldl
                (\canFieldType ( accBuilder, count ) ->
                    let
                        monoFieldType = applySubst subst canFieldType
                        fieldTypeId = lookupTypeIdOrFail monoFieldType state

                        -- For ctor fields, use generic field names
                        ( fieldNameIndex, accWithName ) =
                            getOrCreateStringIndex ("field" ++ String.fromInt count) accBuilder

                        fieldDescriptor =
                            { nameIndex = fieldNameIndex
                            , typeId = fieldTypeId
                            }

                        newBuilder =
                            { accWithName
                                | fields = fieldDescriptor :: accWithName.fields
                                , nextFieldIndex = accWithName.nextFieldIndex + 1
                            }
                    in
                    ( newBuilder, count + 1 )
                )
                ( builderWithName, 0 )
                ctorData.args

        -- Add ctor descriptor
        ctorDescriptor =
            { ctorId = Index.toInt ctorData.index
            , nameIndex = nameIndex
            , firstField = firstField
            , fieldCount = fieldCount
            }

        finalBuilder =
            { builderWithFields
                | ctors = ctorDescriptor :: builderWithFields.ctors
                , nextCtorIndex = builderWithFields.nextCtorIndex + 1
            }
    in
    finalBuilder
```

### Step 4.7: Integrate type registration into specialization

Call `registerMonoType` at key points in `specializeNode` and `specializeExpr`:

```elm
specializeNode : MonoState -> ... -> ( Mono.MonoNode, MonoState )
specializeNode state ... =
    ...
    let
        -- Register the node's result type
        ( _, stateWithType ) =
            registerMonoType resultMonoType state
    in
    ...
```

---

## Phase 5: Freeze Type Graph at End of Monomorphization

### Step 5.1: Update `finalState` to freeze the type graph

```elm
-- In monomorphizeFromEntry or wherever the final MonoGraph is constructed

let
    stateAfterWorklist =
        processWorklist stateWithMain

    -- Freeze the type graph builder into immutable MonoTypeGraph
    frozenTypeGraph =
        MonoTypeGraph.freeze stateAfterWorklist.typeGraphBuilder
in
Ok
    (Mono.MonoGraph
        { nodes = stateAfterWorklist.nodes
        , main = Just mainInfo
        , registry = stateAfterWorklist.registry
        , typeGraph = frozenTypeGraph   -- NEW
        }
    )
```

---

## Phase 6: Assemble UnionEnv in Builder/Generate.elm

### Step 6.1: Update `generateMonoDevOutput` to build and pass `UnionEnv`

```elm
generateMonoDevOutput : CodeGen.MonoCodeGen -> Bool -> Int -> FilePath -> NE.Nonempty Build.Root -> TypedObjects -> Task Exit.Generate CodeGen.Output
generateMonoDevOutput backend withSourceMaps leadingLines root roots objects =
    let
        mode = Mode.Dev Nothing

        typedGraph = typedObjectsToGlobalGraph objects

        -- NEW: Assemble UnionEnv from canonical sources
        unionEnv : Mono.UnionEnv
        unionEnv =
            buildUnionEnv objects
    in
    case Monomorphize.monomorphize "main" typedGraph unionEnv of
        Err err ->
            Task.throw (Exit.GenerateMonomorphizationError err)

        Ok monoGraph ->
            prepareSourceMaps withSourceMaps root
                |> Task.map (generateMonoOutput backend leadingLines mode monoGraph)
```

### Step 6.2: Create `buildUnionEnv` function

This function needs to extract `Can.Union` from:
1. **TypedCanonical modules** (root modules): `TypedCanonical.ModuleData.unions`
2. **Dependency interfaces**: `I.Interface` unions via `extractUnion`

```elm
buildUnionEnv : TypedObjects -> Mono.UnionEnv
buildUnionEnv (TypedObjects globals locals) =
    -- Implementation depends on available data
    -- May need to extend TypedObjects to carry canonical module data
    -- OR load separately via Details
    ...
```

**Note**: This is the part that may require extending `TypedObjects` or the loading pipeline to include canonical module data. See Open Issues below.

---

## Phase 7: Simplify MLIR Backend to Serialize Only

### Step 7.1: Remove mutable `TypeRegistry` from `Context`

```elm
-- In Compiler/Generate/CodeGen/MLIR.elm

type alias Context =
    { nextVar : Int
    , nextOpId : Int
    , mode : Mode.Mode
    , registry : Mono.SpecializationRegistry
    , pendingLambdas : List PendingLambda
    , signatures : Dict Int FuncSignature
    , varMappings : Dict String ( String, MlirType )
    , kernelDecls : Dict String ( List MlirType, MlirType )
    , typeGraph : MonoTypeGraph.MonoTypeGraph   -- CHANGED: read-only reference
    }
```

### Step 7.2: Delete type registration functions

Remove from MLIR.elm:
- `type alias TypeRegistry`
- `emptyTypeRegistry`
- `getOrCreateTypeIdForMonoType`
- `registerNestedTypes`
- `registerCtorLayout`
- `type alias TypeTableAccum`
- `processType`, `addPrimitiveType`, `addListType`, `addTupleType`, `addRecordType`, `addCustomType`, `addFunctionType`, `addPolymorphicType`, `addCtorInfo`, `getOrCreateStringIndex`, `lookupTypeId` (the old mutable version)

### Step 7.3: Update `initContext`

```elm
initContext : Mode.Mode -> Mono.SpecializationRegistry -> Dict Int FuncSignature -> MonoTypeGraph.MonoTypeGraph -> Context
initContext mode registry signatures typeGraph =
    { nextVar = 0
    , nextOpId = 0
    , mode = mode
    , registry = registry
    , pendingLambdas = []
    , signatures = signatures
    , varMappings = Dict.empty
    , kernelDecls = Dict.empty
    , typeGraph = typeGraph   -- Store pre-built graph
    }
```

### Step 7.4: Add pure lookup helper

```elm
lookupTypeId : Mono.MonoType -> Context -> Maybe MonoTypeGraph.MonoTypeId
lookupTypeId monoType ctx =
    MonoTypeGraph.lookupTypeId monoType ctx.typeGraph
```

### Step 7.5: Replace `generateTypeTable` with pure serialization

```elm
generateTypeTableFromGraph : MonoTypeGraph.MonoTypeGraph -> MlirOp
generateTypeTableFromGraph typeGraph =
    let
        typesAttr =
            typeGraph.types
                |> List.map descriptorToAttr
                |> ArrayAttr Nothing

        fieldsAttr =
            typeGraph.fields
                |> List.map fieldToAttr
                |> ArrayAttr Nothing

        ctorsAttr =
            typeGraph.ctors
                |> List.map ctorToAttr
                |> ArrayAttr Nothing

        funcArgsAttr =
            typeGraph.funcArgs
                |> List.map (IntAttr Nothing)
                |> ArrayAttr Nothing

        stringsAttr =
            typeGraph.strings
                |> List.map StringAttr
                |> ArrayAttr Nothing
    in
    { name = "eco.type_table"
    , id = ""
    , operands = []
    , results = []
    , attrs =
        Dict.empty
            |> Dict.insert "types" typesAttr
            |> Dict.insert "fields" fieldsAttr
            |> Dict.insert "ctors" ctorsAttr
            |> Dict.insert "func_args" funcArgsAttr
            |> Dict.insert "strings" stringsAttr
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }

-- Helper functions to convert descriptors to MLIR attrs
descriptorToAttr : MonoTypeGraph.TypeDescriptor -> MlirAttr
fieldToAttr : MonoTypeGraph.FieldDescriptor -> MlirAttr
ctorToAttr : MonoTypeGraph.CtorDescriptor -> MlirAttr
```

### Step 7.6: Update `generateModule`

```elm
generateModule : Mode.Mode -> Mono.MonoGraph -> String
generateModule mode (Mono.MonoGraph { nodes, main, registry, typeGraph }) =
    let
        signatures = buildSignatures nodes

        ctx = initContext mode registry signatures typeGraph  -- Pass typeGraph

        ( ops, ctxAfterNodes ) =
            EveryDict.foldl compare
                (\specId node ( accOps, accCtx ) ->
                    let ( op, newCtx ) = generateNode accCtx specId node
                    in ( accOps ++ [ op ], newCtx )
                )
                ( [], ctx )
                nodes

        ( lambdaOps, finalCtx ) = processLambdas ctxAfterNodes

        mainOps =
            case main of
                Just mainInfo -> generateMainEntry finalCtx mainInfo
                Nothing -> []

        ( kernelDeclOps, _ ) =
            Dict.foldl
                (\name sig ( accOps, accCtx ) ->
                    let ( newCtx, declOp ) = generateKernelDecl accCtx name sig
                    in ( accOps ++ [ declOp ], newCtx )
                )
                ( [], finalCtx )
                finalCtx.kernelDecls

        -- Use pre-built type graph
        typeTableOp = generateTypeTableFromGraph typeGraph

        mlirModule =
            { body = [ typeTableOp ] ++ kernelDeclOps ++ lambdaOps ++ ops ++ mainOps
            , loc = Loc.unknown
            }
    in
    Pretty.ppModule mlirModule
```

---

## Files to Modify

| File | Action | Changes |
|------|--------|---------|
| `compiler/src/Compiler/AST/MonoTypeGraph.elm` | **CREATE** | Type graph data structures, builder, freeze, lookup |
| `compiler/src/Compiler/AST/Monomorphized.elm` | **MODIFY** | Add `UnionEnv` type, add `typeGraph` field to `MonoGraph` |
| `compiler/src/Compiler/Generate/Monomorphize.elm` | **MODIFY** | Add `UnionRegistry`, `TypeGraphBuilder` to state; update `monomorphize` signature; add type registration functions |
| `compiler/src/Builder/Generate.elm` | **MODIFY** | Build `UnionEnv`, pass to `monomorphize` |
| `compiler/src/Compiler/Generate/CodeGen/MLIR.elm` | **MODIFY** | Remove mutable `TypeRegistry`, use pre-built graph for serialization only |

---

## Implementation Order

1. **Phase 1**: Create `MonoTypeGraph.elm` with data structures
2. **Phase 2**: Add internal `UnionRegistry` types to `Monomorphize.elm`
3. **Phase 3**: Update `MonoState` and `monomorphize` signature
4. **Phase 4**: Implement `registerMonoType` and integrate with specialization
5. **Phase 5**: Freeze type graph at end of monomorphization
6. **Phase 6**: Build `UnionEnv` in `Builder/Generate.elm`
7. **Phase 7**: Simplify MLIR backend to serialize-only
8. **Testing**: Verify all ctors appear including unused ones

---

## Open Issues and Questions

### Issue 1: Building `UnionEnv` in Builder/Generate.elm

**Problem**: `TypedObjects` currently contains only `TOpt.GlobalGraph` and local graphs, not canonical module data with `Can.Union` definitions.

**Options**:
1. **Extend `TypedObjects`** to also carry canonical module data
2. **Load canonical data separately** via existing loaders
3. **Extend loading pipeline** to include unions alongside typed objects

**Question**: What's the best way to access `Can.Union` data in `generateMonoDevOutput`? Is canonical module data already available somewhere in the loading pipeline, or do we need to add it?

**Sources for Can.Union**:
- `TypedCanonical.ModuleData.unions` for root modules
- `I.Interface` unions via `extractUnion` for dependencies

### Issue 2: Kernel Type Registration

**Assumption**: Kernel types derived via `deriveKernelAbiType` will be registered by the same `registerMonoType` mechanism when processing `MonoVarKernel` expressions.

**Question**: Are there any kernel types that wouldn't be reached by traversing `MonoGraph` nodes? If so, we may need explicit kernel type registration.

### Issue 3: Substitution for Generic Constructors

**Assumption**: The existing `buildSubstitutionFromVars` and `applySubst` logic in `Monomorphize.elm` can be reused for instantiating constructor field types.

**Question**: Is there a helper like `buildSubstitutionFromVars : List Name -> List Mono.MonoType -> Substitution` already, or does it need to be created?

### Issue 4: Elm Core Library Types

**Assumption**: Unions from `elm/core` (like `Maybe`, `Result`, `List`) are available in the dependency interfaces and will be included in `UnionEnv`.

**Question**: Are there any special cases for built-in types that bypass the normal interface loading?

---

## Assumptions Made

1. **Existing layout computation is correct**: `buildCtorLayoutFromArity`, `computeRecordLayout`, `computeTupleLayout` produce correct layouts and can be reused.

2. **Monomorphization sees all reachable types**: The worklist-based approach visits all types that could be instantiated at runtime.

3. **Canonical union constructors maintain stable ordering**: `Can.Union.alts` order matches the tag indices used at runtime (constructor indices are from `Can.Ctor.index`).

4. **String table deduplication works**: The `getOrCreateStringIndex` pattern from current MLIR code can be reused.

5. **MONO_010 invariant holds**: After this change, `MonoGraph.typeGraph` will contain every type in the program including all constructors for custom types.

---

## Related Documents

- `design_docs/global-type-graph.md` - Runtime type graph design
- `compiler/src/Compiler/Generate/CodeGen/MLIR.elm` - Current type table implementation
- `compiler/src/Compiler/Generate/Monomorphize.elm` - Monomorphization implementation
- `compiler/src/Compiler/AST/Monomorphized.elm` - MonoType and MonoGraph definitions
