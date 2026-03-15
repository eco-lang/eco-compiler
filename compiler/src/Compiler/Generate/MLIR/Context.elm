module Compiler.Generate.MLIR.Context exposing
    ( Context, FuncSignature, PendingLambda, TypeRegistry, VarInfo
    , initContext
    , freshVar, freshOpId, lookupVar, addVarMapping, addDecoderExpr, ctxForSiblingRegion
    , getOrCreateTypeIdForMonoType, registerKernelCall
    , buildSignatures, kernelFuncSignatureFromType
    , isTypeVar, hasKernelImplementation
    , KernelBackendAbiPolicy(..), kernelBackendAbiPolicy
    )

{-| MLIR code generation context.

This module provides the Context type and related utilities for tracking
state during MLIR code generation.


# Types

@docs Context, FuncSignature, PendingLambda, TypeRegistry, VarInfo


# Context Management

@docs initContext


# Variable Management

@docs freshVar, freshOpId, lookupVar, addVarMapping, addDecoderExpr


# Type Registration

@docs getOrCreateTypeIdForMonoType, registerKernelCall


# Signature Utilities

@docs buildSignatures, kernelFuncSignatureFromType


# Type Inspection

@docs isTypeVar, hasKernelImplementation


# Kernel Backend ABI Policy

@docs KernelBackendAbiPolicy, kernelBackendAbiPolicy

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.Mode as Mode
import Dict
import Mlir.Mlir exposing (MlirOp, MlirType)
import Set
import Utils.Crash exposing (crash)



-- ====== CONTEXT ======


{-| Function signature for type lookup: param types and return type.

Used for invariant checking and kernel declaration generation.
All staging/call-model decisions are now made in GlobalOpt and stored in Mono.CallInfo.

-}
type alias FuncSignature =
    { paramTypes : List Mono.MonoType
    , returnType : Mono.MonoType
    , evaluatorBoxesAll : Bool -- True for MonoExtern/MonoManagerLeaf: evaluator wrapper always has !eco.value params
    }


{-| Derive a FuncSignature from a monomorphic function type.
Used for kernel functions where we derive the ABI from the Elm type.
-}
kernelFuncSignatureFromType : Mono.MonoType -> FuncSignature
kernelFuncSignatureFromType funcType =
    let
        ( argTypes, retType ) =
            Mono.decomposeFunctionType funcType
    in
    { paramTypes = argTypes
    , returnType = retType
    , evaluatorBoxesAll = False
    }


{-| Backend ABI policy for kernel function calls.

    AllBoxed   -> All args and result are !eco.value in MLIR, regardless of
                  the monomorphized Elm wrapper type. Used for kernels whose
                  C++ implementation uniformly takes boxed uint64_t values
                  (e.g., List.cons).

    ElmDerived -> ABI is derived from the Elm wrapper's funcType via
                  kernelFuncSignatureFromType + monoTypeToAbi. Used for
                  kernels with typed C++ signatures (e.g., Basics.fdiv takes
                  double, String.cons takes uint16_t).

-}
type KernelBackendAbiPolicy
    = AllBoxed
    | ElmDerived


{-| Determine the backend ABI policy for a kernel call.

Only kernels whose C++ implementation takes ALL arguments as boxed
uint64\_t (eco.value) and returns uint64\_t should be marked AllBoxed.
When in doubt, use ElmDerived (safe default — preserves current behavior).

-}
kernelBackendAbiPolicy : String -> String -> KernelBackendAbiPolicy
kernelBackendAbiPolicy home name =
    case ( home, name ) of
        --
        -- AllBoxed: C++ ABI is uniformly uint64_t for all params and return.
        -- Audited against elm-kernel-cpp/src/KernelExports.h.
        --
        -- List: cons, fromArray, toArray, map2..map5, sortBy, sortWith
        ( "List", _ ) ->
            AllBoxed

        -- Utils: compare, equal, notEqual, lt, le, gt, ge, append
        ( "Utils", _ ) ->
            AllBoxed

        -- String.fromNumber: number-polymorphic, C++ takes boxed uint64_t
        ( "String", "fromNumber" ) ->
            AllBoxed

        -- JsArray: C++ ABI now uniformly uint64_t for all params and return.
        -- Integer arguments (index, length, etc.) are boxed Elm Int HPointers
        -- and unboxed inside the C++ implementations.
        ( "JsArray", _ ) ->
            AllBoxed

        -- Json.wrap: polymorphic (a -> Value), C++ inspects heap tag at runtime.
        -- Must be AllBoxed to avoid signature mismatch across monomorphized
        -- call sites (Encode.int passes i64, Encode.string passes !eco.value).
        ( "Json", "wrap" ) ->
            AllBoxed

        --
        -- ElmDerived: C++ ABI has typed (non-uint64_t) params or returns.
        -- ABI is derived from the Elm wrapper's funcType via monoTypeToAbi.
        --
        -- Basics:  double (trig, fdiv, toFloat), int64_t (idiv, modBy, floor, etc.)
        -- Bitwise: all int64_t
        -- Char:    uint16_t, int64_t
        -- String:  length->int64_t, cons(uint16_t,...), slice(int64_t,int64_t,...)
        -- Json:    decodeIndex(int64_t,...), encode(int64_t,...)
        -- Browser: reload(bool), go(int64_t), setViewport(double,double)
        -- Bytes:   int64_t offsets, bool endianness, double floats
        -- Parser:  int64_t offsets
        -- Regex:   infinity->double, int64_t counts
        -- File:    size->int64_t, lastModified->int64_t
        -- Process: sleep(double)
        -- Time:    setInterval(double,...)
        -- Debugger: download(int64_t,...)
        -- Platform: sendToApp->void
        --
        -- Also ElmDerived (all uint64_t in C++ but no mismatch bug today):
        -- Debug, Scheduler, VirtualDom, Url, Http
        --
        _ ->
            ElmDerived


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


{-| Variable info for tracking SSA variables with their types.
-}
type alias VarInfo =
    { ssaVar : String
    , mlirType : MlirType
    }


{-| MLIR code generation context holding state during code generation.
-}
type alias Context =
    { nextVar : Int
    , nextOpId : Int
    , mode : Mode.Mode
    , registry : Mono.SpecializationRegistry
    , pendingLambdas : List PendingLambda
    , pendingFuncOps : List MlirOp -- Pre-generated func.func ops (e.g. from local tail-rec functions)
    , signatures : Dict.Dict Int FuncSignature -- SpecId -> signature for invariant checking
    , varMappings : Dict.Dict String VarInfo -- Let-bound name -> variable info with call model
    , currentLetSiblings : Dict.Dict String VarInfo -- Sibling mappings for current let-rec group
    , kernelDecls : Dict.Dict String ( List MlirType, MlirType ) -- Kernel function name -> (argTypes, returnType)
    , typeRegistry : TypeRegistry -- Type graph: MonoType -> TypeId for debug printing
    , decoderExprs : Dict.Dict String Mono.MonoExpr -- Cache of let-bound decoder expressions for BytesFusion
    , externBoxedVars : Set.Set String -- Local vars that alias extern/kernel functions (evaluator has all !eco.value params)
    }


{-| Registry for mapping MonoTypes to TypeIds for the global type graph.
Used by eco.dbg with arg\_type\_ids for typed debug printing.
-}
type alias TypeRegistry =
    { nextTypeId : Int
    , typeIds : Dict.Dict (List String) Int -- comparable key -> TypeId
    , typeInfos : List ( Int, Mono.MonoType ) -- List of (TypeId, MonoType) for building type table
    , ctorShapes : Dict.Dict (List String) (List Mono.CtorShape) -- type key -> ctor shapes for custom types
    }


{-| A pending lambda to be generated as a separate function.
-}
type alias PendingLambda =
    { name : String
    , captures : List ( Name.Name, Mono.MonoType )
    , params : List ( Name.Name, Mono.MonoType )
    , body : Mono.MonoExpr
    , returnType : Mono.MonoType -- Explicit return type for typed ABI
    , siblingMappings : Dict.Dict String VarInfo -- For mutually recursive let bindings
    , isTailRecursive : Bool -- True for local tail-recursive functions (MonoTailDef)
    }


{-| Initialize a code generation context.
-}
initContext : Mode.Mode -> Mono.SpecializationRegistry -> Dict.Dict Int FuncSignature -> Dict.Dict (List String) (List Mono.CtorShape) -> Context
initContext mode registry signatures initialCtorShapes =
    { nextVar = 0
    , nextOpId = 0
    , mode = mode
    , registry = registry
    , pendingLambdas = []
    , pendingFuncOps = []
    , signatures = signatures
    , varMappings = Dict.empty
    , currentLetSiblings = Dict.empty
    , kernelDecls = Dict.empty
    , typeRegistry =
        { emptyTypeRegistry
            | ctorShapes = initialCtorShapes
        }
    , decoderExprs = Dict.empty
    , externBoxedVars = Set.empty
    }


{-| Empty type registry for initialization.
-}
emptyTypeRegistry : TypeRegistry
emptyTypeRegistry =
    { nextTypeId = 0
    , typeIds = Dict.empty
    , typeInfos = []
    , ctorShapes = Dict.empty
    }


{-| Get or create a TypeId for a MonoType.
If the type already exists in the registry, returns the existing TypeId.
Otherwise, creates a new TypeId and registers the type.
-}
getOrCreateTypeIdForMonoType : Mono.MonoType -> Context -> ( Int, Context )
getOrCreateTypeIdForMonoType monoType ctx =
    -- Use an iterative worklist approach to avoid stack overflow on deeply nested types
    let
        -- Helper: get all immediate nested types for a MonoType
        getNestedTypes : Mono.MonoType -> Context -> List Mono.MonoType
        getNestedTypes mt c =
            case mt of
                Mono.MList elemType ->
                    [ elemType ]

                Mono.MTuple elementTypes ->
                    elementTypes

                Mono.MRecord fields ->
                    Dict.values fields

                Mono.MCustom _ _ args ->
                    -- Include type args and constructor field types
                    let
                        customKey =
                            Mono.toComparableMonoType mt

                        ctorShapesForType =
                            Dict.get customKey c.typeRegistry.ctorShapes
                                |> Maybe.withDefault []

                        fieldTypes =
                            List.concatMap .fieldTypes ctorShapesForType
                                |> List.filter
                                    (\ft ->
                                        -- Exclude direct self-references to avoid infinite work
                                        Mono.toComparableMonoType ft /= customKey
                                    )
                    in
                    args ++ fieldTypes

                Mono.MFunction argTypes resultType ->
                    argTypes ++ [ resultType ]

                Mono.MInt ->
                    []

                Mono.MFloat ->
                    []

                Mono.MChar ->
                    []

                Mono.MBool ->
                    []

                Mono.MString ->
                    []

                Mono.MUnit ->
                    []

                Mono.MVar _ _ ->
                    []


        -- Register a single type (assuming all nested types are already registered)
        registerSingleType : Mono.MonoType -> Context -> Context
        registerSingleType mt c =
            let
                typeKey =
                    Mono.toComparableMonoType mt

                reg =
                    c.typeRegistry
            in
            case Dict.get typeKey reg.typeIds of
                Just _ ->
                    -- Already registered
                    c

                Nothing ->
                    let
                        typeId =
                            reg.nextTypeId

                        newReg =
                            { nextTypeId = typeId + 1
                            , typeIds = Dict.insert typeKey typeId reg.typeIds
                            , typeInfos = ( typeId, mt ) :: reg.typeInfos
                            , ctorShapes = reg.ctorShapes
                            }
                    in
                    { c | typeRegistry = newReg }

        -- Process the worklist iteratively
        -- We use two lists: 'pending' for types to explore, 'toRegister' for types in reverse topological order
        processWorklist : List Mono.MonoType -> List Mono.MonoType -> Context -> Context
        processWorklist pending toRegister c =
            case pending of
                [] ->
                    -- All types collected, now register them in order (deepest first)
                    List.foldl registerSingleType c toRegister

                current :: rest ->
                    let
                        currentKey =
                            Mono.toComparableMonoType current
                    in
                    if Dict.member currentKey c.typeRegistry.typeIds then
                        -- Already registered, skip
                        processWorklist rest toRegister c

                    else if List.any (\t -> Mono.toComparableMonoType t == currentKey) toRegister then
                        -- Already in toRegister list, skip
                        processWorklist rest toRegister c

                    else
                        -- Add nested types to pending (they need to be processed first)
                        -- Add current to toRegister (it will be registered after its nested types)
                        let
                            nested =
                                getNestedTypes current c
                        in
                        processWorklist (nested ++ rest) (current :: toRegister) c

        -- Run the worklist starting with the requested type
        finalCtx =
            processWorklist [ monoType ] [] ctx

        -- Look up the typeId for the original type
        originalKey =
            Mono.toComparableMonoType monoType
    in
    case Dict.get originalKey finalCtx.typeRegistry.typeIds of
        Just typeId ->
            ( typeId, finalCtx )

        Nothing ->
            -- This shouldn't happen, but provide a fallback
            ( 0, finalCtx )


{-| Construct context for a sibling region in branching constructs.

When generating code for alternative regions (e.g., then/else of scf.if,
alternatives of eco.case), each sibling must forward counters and accumulations
from the previous sibling, but must NOT carry varMappings (since SSA vars defined
in one region are not visible in a sibling region per MLIR scoping rules).

  - `base`: the context BEFORE the branching construct (has correct varMappings)
  - `afterPrevious`: the context AFTER the previous sibling region (has updated counters)

-}
ctxForSiblingRegion : Context -> Context -> Context
ctxForSiblingRegion base afterPrevious =
    { afterPrevious
        | varMappings = base.varMappings
        , externBoxedVars = base.externBoxedVars
    }


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
        Just info ->
            ( info.ssaVar, info.mlirType )

        Nothing ->
            crash ("lookupVar: unbound variable " ++ name)


{-| Add a variable mapping from a let-bound name to its SSA variable and type.
-}
addVarMapping : String -> String -> MlirType -> Context -> Context
addVarMapping name ssaVar mlirTy ctx =
    let
        info : VarInfo
        info =
            { ssaVar = ssaVar
            , mlirType = mlirTy
            }
    in
    { ctx | varMappings = Dict.insert name info ctx.varMappings }


{-| Cache a let-bound expression for BytesFusion decoder resolution.
When a let-binding is compiled, store its original MonoExpr so that
inner decoder fusion can resolve variables defined in outer scopes.
-}
addDecoderExpr : String -> Mono.MonoExpr -> Context -> Context
addDecoderExpr name expr ctx =
    { ctx | decoderExprs = Dict.insert name expr ctx.decoderExprs }



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
                let
                    showTypes ts =
                        ts |> List.map Types.mlirTypeToString |> String.join ", "
                in
                crash
                    ("Kernel signature mismatch for "
                        ++ name
                        ++ ": existing ("
                        ++ showTypes existingArgs
                        ++ " -> "
                        ++ Types.mlirTypeToString existingReturn
                        ++ ") vs new ("
                        ++ showTypes callSiteArgTypes
                        ++ " -> "
                        ++ Types.mlirTypeToString callSiteReturnType
                        ++ ")"
                    )



-- ====== SIGNATURE EXTRACTION (for invariant checking)


{-| Extract the function signature (param types, return type) from a MonoNode.
Returns Nothing for nodes that aren't callable functions.

This is a pure type extractor. All staging/call-model decisions are made in GlobalOpt.

-}
extractNodeSignature : Mono.MonoNode -> Maybe FuncSignature
extractNodeSignature node =
    case node of
        Mono.MonoDefine expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo _ _ ->
                    let
                        extractedReturnType =
                            case monoType of
                                Mono.MFunction _ retType ->
                                    retType

                                _ ->
                                    monoType
                    in
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = extractedReturnType
                        , evaluatorBoxesAll = False
                        }

                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        , evaluatorBoxesAll = False
                        }

        Mono.MonoTailFunc params _ monoType ->
            let
                returnType =
                    case monoType of
                        Mono.MFunction _ ret ->
                            ret

                        _ ->
                            monoType
            in
            Just
                { paramTypes = List.map Tuple.second params
                , returnType = returnType
                , evaluatorBoxesAll = False
                }

        Mono.MonoCtor ctorShape monoType ->
            Just
                { paramTypes = ctorShape.fieldTypes
                , returnType = monoType
                , evaluatorBoxesAll = False
                }

        Mono.MonoEnum _ monoType ->
            Just
                { paramTypes = []
                , returnType = monoType
                , evaluatorBoxesAll = False
                }

        Mono.MonoExtern monoType ->
            case monoType of
                Mono.MFunction _ _ ->
                    let
                        ( argMonoTypes, resultMonoType ) =
                            Mono.decomposeFunctionType monoType
                    in
                    Just
                        { paramTypes = argMonoTypes
                        , returnType = resultMonoType
                        , evaluatorBoxesAll = True
                        }

                _ ->
                    Nothing

        Mono.MonoManagerLeaf _ monoType ->
            case monoType of
                Mono.MFunction _ _ ->
                    let
                        ( argMonoTypes, resultMonoType ) =
                            Mono.decomposeFunctionType monoType
                    in
                    Just
                        { paramTypes = argMonoTypes
                        , returnType = resultMonoType
                        , evaluatorBoxesAll = True
                        }

                _ ->
                    Nothing

        Mono.MonoPortIncoming expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo _ _ ->
                    let
                        extractedReturnType =
                            case monoType of
                                Mono.MFunction _ retType ->
                                    retType

                                _ ->
                                    monoType
                    in
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = extractedReturnType
                        , evaluatorBoxesAll = False
                        }

                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        , evaluatorBoxesAll = False
                        }

        Mono.MonoPortOutgoing expr monoType ->
            case expr of
                Mono.MonoClosure closureInfo _ _ ->
                    let
                        extractedReturnType =
                            case monoType of
                                Mono.MFunction _ retType ->
                                    retType

                                _ ->
                                    monoType
                    in
                    Just
                        { paramTypes = List.map Tuple.second closureInfo.params
                        , returnType = extractedReturnType
                        , evaluatorBoxesAll = False
                        }

                _ ->
                    Just
                        { paramTypes = []
                        , returnType = monoType
                        , evaluatorBoxesAll = False
                        }

        Mono.MonoCycle _ monoType ->
            Just
                { paramTypes = []
                , returnType = monoType
                , evaluatorBoxesAll = False
                }


{-| Build a map of SpecId -> FuncSignature from all nodes in the graph.
Used for invariant checking at call sites.
-}
buildSignatures : Array (Maybe Mono.MonoNode) -> Dict.Dict Int FuncSignature
buildSignatures nodes =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Just node ->
                    case extractNodeSignature node of
                        Just sig ->
                            ( specId + 1, Dict.insert specId sig acc )

                        Nothing ->
                            ( specId + 1, acc )

                Nothing ->
                    ( specId + 1, acc )
        )
        ( 0, Dict.empty )
        nodes
        |> Tuple.second
