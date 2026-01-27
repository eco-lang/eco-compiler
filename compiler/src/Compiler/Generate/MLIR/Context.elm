module Compiler.Generate.MLIR.Context exposing
    ( Context, FuncSignature, PendingLambda, TypeRegistry
    , initContext
    , freshVar, freshOpId, lookupVar, addVarMapping
    , getOrCreateTypeIdForMonoType, registerKernelCall
    , buildSignatures, kernelFuncSignatureFromType
    , isTypeVar, hasKernelImplementation
    )

{-| MLIR code generation context.

This module provides the Context type and related utilities for tracking
state during MLIR code generation.


# Types

@docs Context, FuncSignature, PendingLambda, TypeRegistry


# Context Management

@docs initContext


# Variable Management

@docs freshVar, freshOpId, lookupVar, addVarMapping


# Type Registration

@docs getOrCreateTypeIdForMonoType, registerKernelCall


# Signature Utilities

@docs buildSignatures, kernelFuncSignatureFromType


# Type Inspection

@docs isTypeVar, hasKernelImplementation

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.Mode as Mode
import Data.Map as EveryDict
import Dict
import Mlir.Mlir exposing (MlirType)
import Utils.Crash exposing (crash)



-- ====== CONTEXT ======


{-| Function signature for invariant checking: param types and return type
-}
type alias FuncSignature =
    { paramTypes : List Mono.MonoType
    , returnType : Mono.MonoType
    }


{-| Derive a FuncSignature from a monomorphic function type.
Used for kernel functions where we derive the ABI from the Elm type.
-}
kernelFuncSignatureFromType : Mono.MonoType -> FuncSignature
kernelFuncSignatureFromType funcType =
    let
        ( argTypes, retType ) =
            Types.decomposeFunctionType funcType
    in
    { paramTypes = argTypes
    , returnType = retType
    }


{-| Check if a type is a type variable (MVar).
Used for relaxed intrinsic matching when the result type might be polymorphic.
-}
isTypeVar : Mono.MonoType -> Bool
isTypeVar t =
    case t of
        Mono.MVar _ _ ->
            True

        _ ->
            False


{-| Check if a core module function has a kernel implementation to fall back to
when intrinsics don't match (e.g., due to type mismatches with boxed values).

With relaxed intrinsic matching (matching on argument types only, not result types),
we no longer need kernel fallbacks for negate and not. The intrinsics should always
match for concrete Int, Float, or Bool argument types.

-}
hasKernelImplementation : String -> String -> Bool
hasKernelImplementation _ _ =
    False


{-| MLIR code generation context holding state during code generation.
-}
type alias Context =
    { nextVar : Int
    , nextOpId : Int
    , mode : Mode.Mode
    , registry : Mono.SpecializationRegistry
    , pendingLambdas : List PendingLambda
    , signatures : Dict.Dict Int FuncSignature -- SpecId -> signature for invariant checking
    , varMappings : Dict.Dict String ( String, MlirType ) -- Let-bound name -> (SSA variable name, MLIR type)
    , currentLetSiblings : Dict.Dict String ( String, MlirType ) -- Sibling mappings for current let-rec group
    , kernelDecls : Dict.Dict String ( List MlirType, MlirType ) -- Kernel function name -> (argTypes, returnType)
    , typeRegistry : TypeRegistry -- Type graph: MonoType -> TypeId for debug printing
    }


{-| Registry for mapping MonoTypes to TypeIds for the global type graph.
Used by eco.dbg with arg\_type\_ids for typed debug printing.
-}
type alias TypeRegistry =
    { nextTypeId : Int
    , typeIds : Dict.Dict (List String) Int -- comparable key -> TypeId
    , typeInfos : List ( Int, Mono.MonoType ) -- List of (TypeId, MonoType) for building type table
    , ctorShapes : EveryDict.Dict (List String) (List String) (List Mono.CtorShape) -- type key -> ctor shapes for custom types
    }


{-| A pending lambda to be generated as a separate function.
-}
type alias PendingLambda =
    { name : String
    , captures : List ( Name.Name, Mono.MonoType )
    , params : List ( Name.Name, Mono.MonoType )
    , body : Mono.MonoExpr
    , returnType : Mono.MonoType -- Explicit return type for typed ABI
    , siblingMappings : Dict.Dict String ( String, MlirType ) -- For mutually recursive let bindings
    }


{-| Initialize a code generation context.
-}
initContext : Mode.Mode -> Mono.SpecializationRegistry -> Dict.Dict Int FuncSignature -> EveryDict.Dict (List String) (List String) (List Mono.CtorShape) -> Context
initContext mode registry signatures initialCtorShapes =
    { nextVar = 0
    , nextOpId = 0
    , mode = mode
    , registry = registry
    , pendingLambdas = []
    , signatures = signatures
    , varMappings = Dict.empty
    , currentLetSiblings = Dict.empty
    , kernelDecls = Dict.empty
    , typeRegistry =
        { emptyTypeRegistry
            | ctorShapes = initialCtorShapes
        }
    }


{-| Empty type registry for initialization.
-}
emptyTypeRegistry : TypeRegistry
emptyTypeRegistry =
    { nextTypeId = 0
    , typeIds = Dict.empty
    , typeInfos = []
    , ctorShapes = EveryDict.empty
    }


{-| Get or create a TypeId for a MonoType.
If the type already exists in the registry, returns the existing TypeId.
Otherwise, creates a new TypeId and registers the type.
-}
getOrCreateTypeIdForMonoType : Mono.MonoType -> Context -> ( Int, Context )
getOrCreateTypeIdForMonoType monoType ctx =
    let
        key =
            Mono.toComparableMonoType monoType

        reg =
            ctx.typeRegistry
    in
    case Dict.get key reg.typeIds of
        Just typeId ->
            ( typeId, ctx )

        Nothing ->
            -- First, recursively register any nested types
            let
                ctxWithNested =
                    registerNestedTypes monoType ctx

                regAfterNested =
                    ctxWithNested.typeRegistry

                typeId =
                    regAfterNested.nextTypeId

                newReg =
                    { nextTypeId = typeId + 1
                    , typeIds = Dict.insert key typeId regAfterNested.typeIds
                    , typeInfos = ( typeId, monoType ) :: regAfterNested.typeInfos
                    , ctorShapes = regAfterNested.ctorShapes
                    }
            in
            ( typeId, { ctxWithNested | typeRegistry = newReg } )


{-| Register nested types for a MonoType.
This ensures all element/field/argument types are registered before the containing type.
-}
registerNestedTypes : Mono.MonoType -> Context -> Context
registerNestedTypes monoType ctx =
    case monoType of
        Mono.MList elemType ->
            -- Register element type
            Tuple.second (getOrCreateTypeIdForMonoType elemType ctx)

        Mono.MTuple elementTypes ->
            -- Register all element types
            List.foldl
                (\elemType accCtx ->
                    Tuple.second (getOrCreateTypeIdForMonoType elemType accCtx)
                )
                ctx
                elementTypes

        Mono.MRecord fields ->
            -- Register all field types
            List.foldl
                (\fieldType accCtx ->
                    Tuple.second (getOrCreateTypeIdForMonoType fieldType accCtx)
                )
                ctx
                (EveryDict.values compare fields)

        Mono.MCustom _ _ args ->
            -- Register all type argument types
            List.foldl
                (\argType accCtx ->
                    Tuple.second (getOrCreateTypeIdForMonoType argType accCtx)
                )
                ctx
                args

        Mono.MFunction argTypes resultType ->
            -- Register all argument types and result type
            let
                ctxWithArgs =
                    List.foldl
                        (\argType accCtx ->
                            Tuple.second (getOrCreateTypeIdForMonoType argType accCtx)
                        )
                        ctx
                        argTypes
            in
            Tuple.second (getOrCreateTypeIdForMonoType resultType ctxWithArgs)

        -- Primitives have no nested types
        Mono.MInt ->
            ctx

        Mono.MFloat ->
            ctx

        Mono.MChar ->
            ctx

        Mono.MBool ->
            ctx

        Mono.MString ->
            ctx

        Mono.MUnit ->
            ctx

        Mono.MVar _ _ ->
            ctx


{-| Generate a fresh SSA variable name.
-}
freshVar : Context -> ( String, Context )
freshVar ctx =
    ( "%" ++ String.fromInt ctx.nextVar
    , { ctx | nextVar = ctx.nextVar + 1 }
    )


{-| Generate a fresh operation ID for MLIR operations.
-}
freshOpId : Context -> ( String, Context )
freshOpId ctx =
    ( "op" ++ String.fromInt ctx.nextOpId
    , { ctx | nextOpId = ctx.nextOpId + 1 }
    )


{-| Look up a variable name, checking varMappings first for let-bound aliases.
This allows let bindings to directly reference the SSA variable from the expression
rather than going through an eco.construct wrapper.
Returns both the SSA variable name and its MLIR type.
-}
lookupVar : Context -> String -> ( String, MlirType )
lookupVar ctx name =
    case Dict.get name ctx.varMappings of
        Just ( ssaVar, mlirTy ) ->
            ( ssaVar, mlirTy )

        Nothing ->
            ( "%" ++ name, Types.ecoValue )


{-| Add a variable mapping from a let-bound name to its SSA variable and type.
-}
addVarMapping : String -> String -> MlirType -> Context -> Context
addVarMapping name ssaVar mlirTy ctx =
    { ctx | varMappings = Dict.insert name ( ssaVar, mlirTy ) ctx.varMappings }



-- ======= KERNEL DECLARATION TRACKING


{-| Register a kernel function call, tracking it for declaration generation.

The canonical signature for a kernel is taken directly from the call site.
Subsequent calls to the same kernel name must use exactly the same argument
and result MLIR types, or we crash with a mismatch error.

This keeps declaration generation in sync with the ABI chosen at the call
site (which is derived from the Elm MonoType via Types.monoTypeToMlir).

-}
registerKernelCall : Context -> String -> List MlirType -> MlirType -> Context
registerKernelCall ctx name callSiteArgTypes callSiteReturnType =
    case Dict.get name ctx.kernelDecls of
        Nothing ->
            { ctx
                | kernelDecls =
                    Dict.insert name ( callSiteArgTypes, callSiteReturnType ) ctx.kernelDecls
            }

        Just ( existingArgs, existingReturn ) ->
            if existingArgs == callSiteArgTypes && existingReturn == callSiteReturnType then
                ctx

            else
                crash
                    ("Kernel signature mismatch for "
                        ++ name
                        ++ ": existing ("
                        ++ Debug.toString existingArgs
                        ++ " -> "
                        ++ Debug.toString existingReturn
                        ++ ") vs new ("
                        ++ Debug.toString callSiteArgTypes
                        ++ " -> "
                        ++ Debug.toString callSiteReturnType
                        ++ ")"
                    )



-- ====== SIGNATURE EXTRACTION (for invariant checking)


{-| Extract the function signature (param types, return type) from a MonoNode.
Returns Nothing for nodes that aren't callable functions.
-}
extractNodeSignature : Mono.MonoNode -> Maybe FuncSignature
extractNodeSignature node =
    case node of
        Mono.MonoDefine expr monoType ->
            -- For defines, check if the expression is a closure
            case expr of
                Mono.MonoClosure closureInfo body _ ->
                    -- Function with params
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = Mono.typeOf body
                        }

                _ ->
                    -- Thunk (nullary function) - no params
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        }

        Mono.MonoTailFunc params _ monoType ->
            -- monoType is the full function type (MFunction args returnType)
            -- Extract the actual return type from it
            let
                returnType =
                    case monoType of
                        Mono.MFunction _ ret ->
                            ret

                        _ ->
                            -- Shouldn't happen per MONO_004 invariant
                            monoType
            in
            Just
                { paramTypes = List.map Tuple.second params
                , returnType = returnType
                }

        Mono.MonoCtor ctorShape monoType ->
            -- Constructor - params are the field types
            Just
                { paramTypes = ctorShape.fieldTypes
                , returnType = monoType
                }

        Mono.MonoEnum _ monoType ->
            -- Nullary enum constructor
            Just
                { paramTypes = []
                , returnType = monoType
                }

        Mono.MonoExtern monoType ->
            -- External value or function.
            -- If it's a function type, decompose it to get arguments + result.
            case monoType of
                Mono.MFunction _ _ ->
                    let
                        ( argMonoTypes, resultMonoType ) =
                            Types.decomposeFunctionType monoType
                    in
                    Just
                        { paramTypes = argMonoTypes
                        , returnType = resultMonoType
                        }

                -- Non-function externs are not callable; no signature.
                _ ->
                    Nothing

        Mono.MonoPortIncoming expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo body _ ->
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = Mono.typeOf body
                        }

                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        }

        Mono.MonoPortOutgoing expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo body _ ->
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = Mono.typeOf body
                        }

                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        }

        Mono.MonoCycle _ monoType ->
            Just
                { paramTypes = []
                , returnType = monoType
                }


{-| Build a map of SpecId -> FuncSignature from all nodes in the graph.
Used for invariant checking at call sites.
-}
buildSignatures : EveryDict.Dict Int Int Mono.MonoNode -> Dict.Dict Int FuncSignature
buildSignatures nodes =
    EveryDict.foldl compare
        (\specId node acc ->
            case extractNodeSignature node of
                Just sig ->
                    Dict.insert specId sig acc

                Nothing ->
                    acc
        )
        Dict.empty
        nodes
