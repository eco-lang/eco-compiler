module Compiler.Generate.MLIR.Context exposing
    ( Context, FuncSignature, KernelDeclInfo, PendingLambda, TypeRegistry, VarInfo
    , initContext, withInlineBodies, withEcoConfig
    , freshVar, freshOpId, lookupVar, addVarMapping, addDecoderExpr, ctxForSiblingRegion, ctxAfterBranchOp, liveEcoValueVars, resetDefinedSsaVars
    , getOrCreateTypeIdForMonoType, registerKernelCall, registerKernelInstance
    , buildSignatures, kernelFuncSignatureFromType
    , isTypeVar, hasKernelImplementation
    )

{-| MLIR code generation context.

This module provides the Context type and related utilities for tracking
state during MLIR code generation.


# Types

@docs Context, FuncSignature, PendingLambda, TypeRegistry, VarInfo


# Context Management

@docs initContext


# Variable Management

@docs freshVar, freshOpId, lookupVar, addVarMapping, addDecoderExpr, ctxForSiblingRegion, ctxAfterBranchOp, liveEcoValueVars, resetDefinedSsaVars


# Type Registration

@docs getOrCreateTypeIdForMonoType, registerKernelCall


# Signature Utilities

@docs buildSignatures, kernelFuncSignatureFromType


# Type Inspection

@docs isTypeVar, hasKernelImplementation


# Kernel Declaration Info

@docs KernelDeclInfo


# Kernel Instance Registration

@docs registerKernelInstance

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Eco.Config as Config
import Compiler.Generate.MLIR.Types as Types
import Compiler.Generate.Mode as Mode
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Dict
import Mlir.Mlir exposing (MlirOp, MlirType(..))
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


-- The KernelBackendAbiPolicy type and the kernelBackendAbiPolicy lookup table
-- now live in Compiler.Monomorphize.KernelAbi as part of the per-instance
-- kernel ABI rollout (see plans/per-instance-kernel-abi.md, Phase A).
-- Callers should use KernelAbi.AllBoxed / KernelAbi.ElmDerived /
-- KernelAbi.kernelBackendAbiPolicy directly.


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
    , signatures : Array (Maybe FuncSignature) -- SpecId -> signature for invariant checking
    , varMappings : Dict.Dict String VarInfo -- Let-bound name -> variable info with call model
    , currentLetSiblings : Dict.Dict String VarInfo -- Sibling mappings for current let-rec group
    , kernelDecls : Dict.Dict String KernelDeclInfo -- Kernel symbol -> ABI declaration info
    , typeRegistry : TypeRegistry -- Type graph: MonoType -> TypeId for debug printing
    , decoderExprs : Dict.Dict String Mono.MonoExpr -- Cache of let-bound decoder expressions for BytesFusion
    , externBoxedVars : Set.Set String -- Local vars that alias extern/kernel functions (evaluator has all !eco.value params)
    , definedSsaVars : Set.Set String -- SSA variables defined in the current function scope (for safepoint filtering)
    , inlineBodies : Dict.Dict Int ( List ( Name.Name, Mono.MonoType ), Mono.MonoExpr )
    -- ^ SpecId -> (params, body) of inlinable, non-recursive functions in
    -- the final MonoGraph. Used by the bytes-fusion reifier's
    -- `reifyMapBody` to beta-reduce per-element encoder functions
    -- (closure-converted inline lambdas, `Utils.Bytes.Encode.string`,
    -- etc.) against a synthetic iteration variable so their bodies can
    -- be reified into `ELoop` body nodes. Built once at codegen entry
    -- from `MonoInlineSimplify.buildBodyLookup`.
    , ecoConfig : Config.EcoConfig
    -- ^ Effective project config from eco-config.json. Gates the
    -- bytes-fusion entry (`bytesFusion.enabled`) and tunes logical-type
    -- codegen (`logicalTypes.customMaxFields`). Installed via
    -- `withEcoConfig` at codegen entry; defaults reproduce prior behaviour.
    }


{-| Registry for mapping MonoTypes to TypeIds for the global type graph.
Used by eco.dbg with arg\_type\_ids for typed debug printing.
-}
type alias TypeRegistry =
    { nextTypeId : Int
    , typeIds : Dict.Dict String Int -- comparable key -> TypeId
    , typeInfos : List ( Int, Mono.MonoType ) -- List of (TypeId, MonoType) for building type table
    , ctorShapes : Dict.Dict String (List Mono.CtorShape) -- type key -> ctor shapes for custom types
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
    , selfBindingName : Maybe String -- Elm-level binding name for tail-rec self-reference
    }


{-| Initialize a code generation context.

Callers that want the bytes-fusion reifier to fire on higher-order
encoder patterns must install the `inlineBodies` table after creation
via `withInlineBodies` (built from `MonoInlineSimplify.buildBodyLookup`).
Without it, the reifier's `MonoVarGlobal` mapFn case in `reifyMapBody`
falls back to `Nothing` and ELoop fusion is suppressed for closure-converted
inline lambdas.
-}
initContext : Mode.Mode -> Mono.SpecializationRegistry -> Array (Maybe FuncSignature) -> Dict.Dict String (List Mono.CtorShape) -> Context
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
    , definedSsaVars = Set.empty
    , inlineBodies = Dict.empty
    , ecoConfig = Config.default
    }


{-| Install a body-lookup table on a freshly-initialised Context.
Typically called immediately after `initContext` with the result of
`MonoInlineSimplify.buildBodyLookup`.
-}
withInlineBodies : Dict.Dict Int ( List ( Name.Name, Mono.MonoType ), Mono.MonoExpr ) -> Context -> Context
withInlineBodies bodies ctx =
    { ctx | inlineBodies = bodies }


{-| Install the effective eco-config on a freshly-initialised Context.
Defaults to `Config.default` when not called.
-}
withEcoConfig : Config.EcoConfig -> Context -> Context
withEcoConfig cfg ctx =
    { ctx | ecoConfig = cfg }


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
from the previous sibling, but must NOT carry varMappings or definedSsaVars
(since SSA vars defined in one region are not visible in a sibling region
per MLIR scoping rules).

  - `base`: the context BEFORE the branching construct (has correct varMappings
    and definedSsaVars)
  - `afterPrevious`: the context AFTER the previous sibling region (has updated counters)

-}
ctxForSiblingRegion : Context -> Context -> Context
ctxForSiblingRegion base afterPrevious =
    { afterPrevious
        | varMappings = base.varMappings
        , externBoxedVars = base.externBoxedVars
        , definedSsaVars = base.definedSsaVars
    }


{-| Restore definedSsaVars and varMappings after a branching construct
(eco.case, scf.if, etc.) completes. The returned context keeps counters
and other accumulations from the post-branch context but scopes
definedSsaVars back to the pre-branch state plus any new result variables.

  - `base`: the context BEFORE the branching construct
  - `afterBranch`: the context AFTER all branches have been generated
  - `resultVars`: SSA variable names for the branch op's results

-}
ctxAfterBranchOp : Context -> Context -> List String -> Context
ctxAfterBranchOp base afterBranch resultVars =
    { afterBranch
        | varMappings = base.varMappings
        , definedSsaVars = List.foldl Set.insert base.definedSsaVars resultVars
    }


{-| Generate a fresh SSA variable name.
-}
freshVar : Context -> ( String, Context )
freshVar ctx =
    let
        varName =
            "%" ++ String.fromInt ctx.nextVar
    in
    ( varName
    , { ctx | nextVar = ctx.nextVar + 1, definedSsaVars = Set.insert varName ctx.definedSsaVars }
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
    { ctx | varMappings = Dict.insert name info ctx.varMappings, definedSsaVars = Set.insert ssaVar ctx.definedSsaVars }


{-| Reset definedSsaVars for a new function scope, optionally seeding with
initial SSA variable names (e.g. function parameters and captures).
-}
resetDefinedSsaVars : List String -> Context -> Context
resetDefinedSsaVars initialVars ctx =
    { ctx | definedSsaVars = Set.fromList initialVars }


{-| Phase 2 probe: return an empty front-end GC root hint set, letting
EcoGCPrepare's MLIR `Liveness` analysis alone drive root attachment at
each GCRootCarrier op. The conservative all-in-scope hint set landed in
Phase 1 (full closure of `varMappings` filtered by `definedSsaVars`) is
kept as documentation below for reference; flip back to it if the
EcoGCLivenessAudit pass surfaces missing roots that liveness cannot
recover on its own.

    -- Conservative Phase 1 implementation (restore by inverting the body):
    --     ctx.varMappings
    --         |> Dict.values
    --         |> List.filterMap
    --             (\info ->
    --                 if Set.member info.ssaVar ctx.definedSsaVars then
    --                     case info.mlirType of
    --                         NamedStruct "eco.value" ->
    --                             Just ( info.ssaVar, info.mlirType )
    --
    --                         _ ->
    --                             Nothing
    --
    --                 else
    --                     Nothing
    --             )

-}
liveEcoValueVars : Context -> List ( String, MlirType )
liveEcoValueVars _ =
    []


{-| Cache a let-bound expression for BytesFusion decoder resolution.
When a let-binding is compiled, store its original MonoExpr so that
inner decoder fusion can resolve variables defined in outer scopes.
-}
addDecoderExpr : String -> Mono.MonoExpr -> Context -> Context
addDecoderExpr name expr ctx =
    { ctx | decoderExprs = Dict.insert name expr ctx.decoderExprs }



-- ======= KERNEL DECLARATION TRACKING


{-| Recorded ABI for one kernel symbol. Populated by `registerKernelCall`
(legacy MLIR-types-only path) and `registerKernelInstance` (per-instance path
introduced in Phase A of the per-instance kernel ABI rollout). Backend
iteration uses these fields to emit the matching `func.func private` decl.
-}
type alias KernelDeclInfo =
    { symbolName : String
    , abiArgTypes : List MlirType
    , abiResultType : MlirType
    }


{-| Register a kernel function call, tracking it for declaration generation.

The canonical signature for a kernel is taken directly from the call site.
Subsequent calls to the same kernel name must use exactly the same argument
and result MLIR types, or we crash with a mismatch error (CGEN_038).

This shim keeps the legacy MLIR-types-only entry point working for callers
that have not yet been ported to `registerKernelInstance`. It populates the
same `KernelDeclInfo` records.

-}
registerKernelCall : Context -> String -> List MlirType -> MlirType -> Context
registerKernelCall ctx name callSiteArgTypes callSiteReturnType =
    insertKernelDecl ctx
        { symbolName = name
        , abiArgTypes = callSiteArgTypes
        , abiResultType = callSiteReturnType
        }


{-| Register a per-instance kernel call, returning the resolved ABI for the
caller to use when emitting boxing/unboxing and the `eco.call` operands.

Crashes if a previous call registered a different ABI for the same symbol
(CGEN_038).

-}
registerKernelInstance : KernelAbi.KernelInstanceKey -> Context -> ( KernelAbi.KernelInstanceAbi, Context )
registerKernelInstance key ctx =
    let
        abi : KernelAbi.KernelInstanceAbi
        abi =
            KernelAbi.deriveKernelInstanceAbi key

        info : KernelDeclInfo
        info =
            { symbolName = abi.symbolName
            , abiArgTypes = abi.abiArgTypes
            , abiResultType = abi.abiResultType
            }
    in
    ( abi, insertKernelDecl ctx info )


{-| Insert (or verify) a `KernelDeclInfo` for the given symbol. Crashes on
ABI mismatch with an existing entry (CGEN_038).
-}
insertKernelDecl : Context -> KernelDeclInfo -> Context
insertKernelDecl ctx info =
    case Dict.get info.symbolName ctx.kernelDecls of
        Nothing ->
            { ctx | kernelDecls = Dict.insert info.symbolName info ctx.kernelDecls }

        Just existing ->
            if existing.abiArgTypes == info.abiArgTypes && existing.abiResultType == info.abiResultType then
                ctx

            else
                let
                    showTypes ts =
                        ts |> List.map Types.mlirTypeToString |> String.join ", "
                in
                crash
                    ("Kernel signature mismatch for "
                        ++ info.symbolName
                        ++ ": existing ("
                        ++ showTypes existing.abiArgTypes
                        ++ " -> "
                        ++ Types.mlirTypeToString existing.abiResultType
                        ++ ") vs new ("
                        ++ showTypes info.abiArgTypes
                        ++ " -> "
                        ++ Types.mlirTypeToString info.abiResultType
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


{-| Build a map of SpecId -> FuncSignature from all nodes in the graph.
Used for invariant checking at call sites.
-}
buildSignatures : Array (Maybe Mono.MonoNode) -> Array (Maybe FuncSignature)
buildSignatures nodes =
    Array.map
        (\maybeNode ->
            maybeNode |> Maybe.andThen extractNodeSignature
        )
        nodes
