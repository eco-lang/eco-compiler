module Compiler.Generate.MLIR.Functions exposing (generateMainEntry, generateNode, generateKernelDecl, generateGenericCloneFunc)

{-| Function generation for the MLIR backend.

This module handles generation of all function types:

  - Main entry point
  - Defines (regular functions)
  - Tail functions
  - Constructors
  - Enums
  - Externs
  - Cycles

@docs generateMainEntry, generateNode, generateKernelDecl, generateGenericCloneFunc

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Expr as Expr
import Compiler.Generate.MLIR.LogicalTypes as LogicalTypes
import Compiler.Generate.MLIR.Names as Names
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.TailRec as TailRec
import Compiler.Generate.MLIR.Types as Types
import Compiler.Elm.Package as Pkg
import Utils.Crash exposing (crash)
import Compiler.Monomorphize.Registry as Registry
import Compiler.Reporting.Annotation as A
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirRegion, MlirType(..), Visibility(..))
import Set
import System.TypeCheck.IO as IO



-- ====== GENERATE MAIN ENTRY ======


{-| Generate the main entry point function.
-}
generateMainEntry : Ctx.Context -> List Mono.PortRegistration -> Maybe Mono.SpecId -> Mono.MainInfo -> ( List MlirOp, Ctx.Context )
generateMainEntry ctx ports flagsDecoder mainInfo =
    case mainInfo of
        Mono.StaticMain mainSpecId ->
            let
                ( portFnOps, ctxPorts ) =
                    generateRegisterPorts ctx ports flagsDecoder

                -- main has no block args, so reset scope completely
                ctxMain =
                    { ctxPorts | nextVar = 0, varMappings = Dict.empty, definedSsaVars = Set.empty }

                -- Register ports before the program runs (PORT_003): the
                -- @__eco_register_ports call precedes the Main_main call,
                -- which is what eventually enters Platform.worker.
                ( preambleOps, ctx0 ) =
                    if List.isEmpty portFnOps then
                        ( [], ctxMain )

                    else
                        let
                            ( regVar, ctxA ) =
                                Ctx.freshVar ctxMain

                            ( ctxB, regCallOp ) =
                                Ops.ecoCallNamed ctxA (Expr.emitSafepointHints ctxA) regVar "__eco_register_ports" [] Types.ecoValue
                        in
                        ( [ regCallOp ], ctxB )

                ( callVar, ctx1 ) =
                    Ctx.freshVar ctx0

                mainFuncName : String
                mainFuncName =
                    specIdToFuncName ctx.registry mainSpecId

                ( ctx2, callOp ) =
                    Ops.ecoCallNamed ctx1 (Expr.emitSafepointHints ctx1) callVar mainFuncName [] Types.ecoValue

                ( ctx3, returnOp ) =
                    Ops.ecoReturn ctx2 callVar Types.ecoValue

                region : MlirRegion
                region =
                    Ops.mkRegion [] (preambleOps ++ [ callOp ]) returnOp

                ( ctx4, mainOp0 ) =
                    Ops.funcFunc ctx3 "main" [] Types.ecoValue region

                -- Chunked-list mode marker (plans/chunked-list-representation.md
                -- §6): stamp `eco.list_chunks` on the @main entry func so the
                -- backend lowers list head/tail projections chunk-aware. A
                -- func attr (like eco.shadow_roots) flows through BOTH the
                -- text and bytecode emitters unchanged; EcoToLLVM's pre-scan
                -- walk picks it up.
                mainOp =
                    if ctx.ecoConfig.list.chunks then
                        { mainOp0 | attrs = Dict.insert "eco.list_chunks" UnitAttr mainOp0.attrs }

                    else
                        mainOp0
            in
            -- Return the threaded context: generateRegisterPorts records
            -- the registration kernels in ctx.kernelDecls, and the backend
            -- emits kernel stubs from the context AFTER main generation.
            ( portFnOps ++ [ mainOp ], ctx4 )


{-| Generate the synthetic `@__eco_register_ports` function (PORT\_003).

For every port reached during monomorphization it emits a runtime
registration call before `Platform.worker` runs:

  - incoming: `Elm_Kernel_Platform_registerIncomingPort(name, decoder)`
    where `decoder` is produced by calling the port's Decoder-value thunk
    (the separate specialization recorded in `PortRegistration.decoderSpecId`)
  - outgoing: `Elm_Kernel_Platform_registerOutgoingPort(name)`

Returns `( [], ctx )` for programs without ports so no preamble is
emitted at all.

-}
generateRegisterPorts : Ctx.Context -> List Mono.PortRegistration -> Maybe Mono.SpecId -> ( List MlirOp, Ctx.Context )
generateRegisterPorts ctx0 ports flagsDecoder =
    if List.isEmpty ports && flagsDecoder == Nothing then
        ( [], ctx0 )

    else
        let
            -- Fresh SSA scope for the synthetic function.
            ctxClean =
                { ctx0 | nextVar = 0, varMappings = Dict.empty, definedSsaVars = Set.empty }

            hasIncoming =
                List.any .incoming ports

            hasOutgoing =
                List.any (\p -> not p.incoming) ports

            -- Track the registration kernels so the backend emits their
            -- is_kernel stubs (resolved to the C++ exports at link time).
            ctxKernels =
                ctxClean
                    |> (\c ->
                            if hasIncoming then
                                Ctx.registerKernelCall c
                                    "Elm_Kernel_Platform_registerIncomingPort"
                                    [ Types.ecoValue, Types.ecoValue ]
                                    Types.ecoValue

                            else
                                c
                       )
                    |> (\c ->
                            if hasOutgoing then
                                Ctx.registerKernelCall c
                                    "Elm_Kernel_Platform_registerOutgoingPort"
                                    [ Types.ecoValue ]
                                    Types.ecoValue

                            else
                                c
                       )
                    |> (\c ->
                            if flagsDecoder /= Nothing then
                                Ctx.registerKernelCall c
                                    "Elm_Kernel_Platform_registerFlagsDecoder"
                                    [ Types.ecoValue ]
                                    Types.ecoValue

                            else
                                c
                       )

            -- Flags decoder registration (Phase 5): call the decoder's
            -- value thunk, then hand the decoder to the runtime. Emitted
            -- before the port registrations.
            ( flagsRevOps, ctxAfterFlags ) =
                case flagsDecoder of
                    Nothing ->
                        ( [], ctxKernels )

                    Just decoderSpecId ->
                        let
                            ( decoderVar, c1 ) =
                                Ctx.freshVar ctxKernels

                            ( c2, decoderCallOp ) =
                                Ops.ecoCallNamed c1
                                    (Expr.emitSafepointHints c1)
                                    decoderVar
                                    (specIdToFuncName c1.registry decoderSpecId)
                                    []
                                    Types.ecoValue

                            ( resultVar, c3 ) =
                                Ctx.freshVar c2

                            ( c4, registerOp ) =
                                Ops.ecoCallNamed c3
                                    (Expr.emitSafepointHints c3)
                                    resultVar
                                    "Elm_Kernel_Platform_registerFlagsDecoder"
                                    [ ( decoderVar, Types.ecoValue ) ]
                                    Types.ecoValue
                        in
                        ( [ registerOp, decoderCallOp ], c4 )

            ( revOps, ctxAfterPorts ) =
                List.foldl
                    (\port_ ( accOps, c ) ->
                        let
                            ( nameVar, c1 ) =
                                Ctx.freshVar c

                            ( c2, nameOp ) =
                                Ops.ecoStringLiteral c1 nameVar port_.name
                        in
                        case ( port_.incoming, port_.decoderSpecId ) of
                            ( True, Just decoderSpecId ) ->
                                let
                                    ( decoderVar, c3 ) =
                                        Ctx.freshVar c2

                                    ( c4, decoderCallOp ) =
                                        Ops.ecoCallNamed c3
                                            (Expr.emitSafepointHints c3)
                                            decoderVar
                                            (specIdToFuncName c3.registry decoderSpecId)
                                            []
                                            Types.ecoValue

                                    ( resultVar, c5 ) =
                                        Ctx.freshVar c4

                                    ( c6, registerOp ) =
                                        Ops.ecoCallNamed c5
                                            (Expr.emitSafepointHints c5)
                                            resultVar
                                            "Elm_Kernel_Platform_registerIncomingPort"
                                            [ ( nameVar, Types.ecoValue ), ( decoderVar, Types.ecoValue ) ]
                                            Types.ecoValue
                                in
                                ( registerOp :: decoderCallOp :: nameOp :: accOps, c6 )

                            _ ->
                                let
                                    ( resultVar, c3 ) =
                                        Ctx.freshVar c2

                                    ( c4, registerOp ) =
                                        Ops.ecoCallNamed c3
                                            (Expr.emitSafepointHints c3)
                                            resultVar
                                            "Elm_Kernel_Platform_registerOutgoingPort"
                                            [ ( nameVar, Types.ecoValue ) ]
                                            Types.ecoValue
                                in
                                ( registerOp :: nameOp :: accOps, c4 )
                    )
                    ( [], ctxAfterFlags )
                    ports

            ( unitVar, ctxU ) =
                Ctx.freshVar ctxAfterPorts

            ( ctxU2, unitOp ) =
                Ops.ecoConstantUnit ctxU unitVar

            ( ctxU3, returnOp ) =
                Ops.ecoReturn ctxU2 unitVar Types.ecoValue

            region : MlirRegion
            region =
                Ops.mkRegion [] (List.reverse (revOps ++ flagsRevOps) ++ [ unitOp ]) returnOp

            ( ctxF, funcOp ) =
                Ops.funcFunc ctxU3 "__eco_register_ports" [] Types.ecoValue region
        in
        ( [ funcOp ], ctxF )



-- ====== TIER-B CLOSURE-FREE COMBINATOR SHUNTS (chunked lists) ======


{-| Shunt-eligible elm/core `List` combinators and their arities
(plans/chunked-list-representation.md §6 L1.3 / §9.2). All closure-free —
no LSS devirtualization is at stake — and each has a chunk-producing
kernel export (`Elm_Kernel_List_<name>`, ListExports.cpp) that builds
through `alloc::listFromUnboxables`, replacing the `foldl cons`
per-element cell chains (the L0 census's dominant 498M-cons HOF pool;
`reverse` = `foldl cons []` is the single biggest producer).
-}
listShuntKernels : Dict.Dict Name.Name Int
listShuntKernels =
    Dict.fromList
        [ ( "reverse", 1 )
        , ( "append", 2 )
        , ( "concat", 1 )
        , ( "take", 2 )
        , ( "drop", 2 )
        ]


{-| Under `config.list.chunks`, rewrite a recognized combinator
specialization's body into a direct saturated kernel call. Guarded hard:
only a capture-free `MonoDefine`/`MonoClosure` node whose flat param count
matches the combinator's arity is rewritten (recognition is by
specialization ORIGIN via the registry, so user functions named `reverse`
are never touched); every other shape — staged closures, `MonoTailFunc`
TCO forms (elm/core `drop`), partial stagings — compiles unchanged.
Flag-off this is the identity, so default builds are byte-identical.
-}
listChunksShunt : Ctx.Context -> Mono.SpecId -> Mono.MonoNode -> Mono.MonoNode
listChunksShunt ctx specId node =
    if not ctx.ecoConfig.list.chunks then
        node

    else
        case Registry.lookupSpecKey specId ctx.registry of
            Just ( Mono.Global (IO.Canonical pkg "List") name, _ ) ->
                if pkg == Pkg.core then
                    case Dict.get name listShuntKernels of
                        Just arity ->
                            listShuntNode name arity node

                        Nothing ->
                            node

                else
                    node

            _ ->
                node


listShuntNode : Name.Name -> Int -> Mono.MonoNode -> Mono.MonoNode
listShuntNode kernelName arity node =
    case node of
        Mono.MonoDefine (Mono.MonoClosure ci body ct) nt ->
            if List.isEmpty ci.captures && List.length ci.params == arity then
                Mono.MonoDefine
                    (Mono.MonoClosure ci
                        (listShuntCall kernelName ci.params (Mono.typeOf body))
                        ct
                    )
                    nt

            else
                node

        _ ->
            node


{-| The synthesized body: one saturated `CallDirectFlat` kernel call over
the closure's own params. `CallDirectFlat` routes generateCall to the
ABI-flattened kernel path (KernelAbi derives the C symbol + per-arg ABI
from the concrete param types — e.g. `take`'s `Int` argument crosses as
raw i64, matching the C export's `int64_t`).
-}
listShuntCall : Name.Name -> List ( Name.Name, Mono.MonoType ) -> Mono.MonoType -> Mono.MonoExpr
listShuntCall kernelName params resultTy =
    let
        kernelTy : Mono.MonoType
        kernelTy =
            Mono.mFunction Mono.LTop (List.map Tuple.second params) resultTy

        defaultInfo : Mono.CallInfo
        defaultInfo =
            Mono.defaultCallInfo

        callInfo : Mono.CallInfo
        callInfo =
            { defaultInfo | callKind = Mono.CallDirectFlat }
    in
    Mono.MonoCall A.zero
        (Mono.MonoVarKernel A.zero "Elm" "List" kernelName kernelTy)
        (List.map (\( n, pt ) -> Mono.MonoVarLocal n pt) params)
        resultTy
        callInfo



-- ====== GENERATE NODE ======


{-| Generate MLIR code for a monomorphized node.
Returns a list of MlirOps (may be multiple for closures with captures).
-}
generateNode : Ctx.Context -> Mono.SpecId -> Mono.MonoNode -> ( List MlirOp, Ctx.Context )
generateNode ctx specId node =
    let
        funcName : String
        funcName =
            specIdToFuncName ctx.registry specId

        ( ops, dirtyCtx ) =
            generateNodeInner { ctx | currentFuncName = funcName }
                funcName
                specId
                (listChunksShunt ctx specId node)

        -- Mark the main entrypoint's func.func with eco.shadow_roots so that
        -- EcoToLLVM installs a shadow root frame for its parameters (TCO safety).
        isMainEntry =
            case Registry.lookupSpecKey specId ctx.registry of
                Just ( Mono.Global _ name, _ ) ->
                    name == "main"

                _ ->
                    False

        finalOps =
            if isMainEntry then
                -- main is a MonoDefine thunk too, but its shadow-root frame
                -- epilogues must balance the prologue on EVERY return — a CAF
                -- guard's hit-path early return would skip the frame push.
                -- Strip the memoization here (the C++ installer also skips
                -- shadow-root funcs — belt and braces). main runs once anyway.
                ops
                    |> List.filter (\op -> op.name /= "eco.global")
                    |> List.map (\op -> { op | attrs = Dict.remove "eco.caf_memo" op.attrs })
                    |> List.map addShadowRootsAttr

            else
                ops

        -- Reset varMappings and definedSsaVars after each node.
        -- Each node generates one or more top-level func.func ops, each with
        -- their own SSA scope. The dirty context carries stale var entries
        -- from the node's body compilation that must not leak to the next node.
        cleanCtx =
            { dirtyCtx | varMappings = Dict.empty, definedSsaVars = Set.empty, sretTailLayout = Nothing, splitAggParams = Dict.empty }
    in
    ( finalOps, cleanCtx )


generateNodeInner : Ctx.Context -> String -> Mono.SpecId -> Mono.MonoNode -> ( List MlirOp, Ctx.Context )
generateNodeInner ctx funcName specId node =
    case node of
        Mono.MonoDefine expr monoType ->
            generateDefine ctx funcName True expr monoType (Dict.get specId ctx.sretPromoted) (Dict.get specId ctx.psplitPromoted)

        Mono.MonoTailFunc params expr monoType ->
            generateTailFunc ctx funcName params expr monoType (Dict.get specId ctx.sretPromoted)

        Mono.MonoCtor ctorShape monoType ->
            let
                ctorLayout =
                    Types.computeCtorLayout ctorShape

                ( ctx1, op ) =
                    generateCtor ctx funcName ctorLayout monoType
            in
            ( [ op ], ctx1 )

        Mono.MonoEnum tag monoType ->
            let
                -- Look up the spec key to get the constructor name
                maybeCtorName : Maybe String
                maybeCtorName =
                    case Registry.lookupSpecKey specId ctx.registry of
                        Just ( Mono.Global _ ctorName, _ ) ->
                            Just (Name.toElmString ctorName)

                        Just ( Mono.Accessor _, _ ) ->
                            -- Accessors don't have constructor names
                            Nothing

                        Nothing ->
                            Nothing

                ( ctx1, op ) =
                    generateEnum ctx funcName tag monoType maybeCtorName

                -- M4 (plans/caf-memoization-implementation.md): nullary custom
                -- constructors allocate a fresh object per reference
                -- (eco.construct.custom size 0) — give them CAF slots too, so
                -- each enum spec allocates once per process. Well-known
                -- constants (True/False/Nothing) compile to embedded-constant
                -- immediates: trivial bodies, a guard would only add cost.
                -- Sharing is sound: constructed customs are immutable once
                -- escaped (HEAP_031) and equality/dispatch are tag-based
                -- (bit-equality even improves on a shared object).
                isWellKnownConstant =
                    List.member maybeCtorName [ Just "True", Just "False", Just "Nothing" ]

                cafQualifies =
                    ctx.ecoConfig.cafMemo.enabled
                        && not isWellKnownConstant
            in
            if cafQualifies then
                let
                    ( ctx2, globalOp ) =
                        Ops.ecoGlobal ctx1 (cafSlotName funcName)

                    opTagged =
                        { op | attrs = Dict.insert "eco.caf_memo" UnitAttr op.attrs }
                in
                ( [ globalOp, opTagged ], ctx2 )

            else
                ( [ op ], ctx1 )

        Mono.MonoExtern monoType ->
            let
                ( ctx1, op ) =
                    generateExtern ctx funcName monoType
            in
            ( [ op ], ctx1 )

        Mono.MonoManagerLeaf homeModuleName monoType ->
            let
                ( ctx1, op ) =
                    generateManagerLeaf ctx funcName homeModuleName monoType
            in
            ( [ op ], ctx1 )

        -- Ports stay unmemoized (PORT_003: the registration preamble owns
        -- their lifecycle); port DECODER specs are plain MonoDefines above
        -- and memoize normally.
        Mono.MonoPortIncoming expr monoType ->
            generateDefine ctx funcName False expr monoType Nothing Nothing

        Mono.MonoPortOutgoing expr monoType ->
            generateDefine ctx funcName False expr monoType Nothing Nothing


specIdToFuncName : Mono.SpecializationRegistry -> Mono.SpecId -> String
specIdToFuncName registry specId =
    case Registry.lookupSpecKey specId registry of
        Just ( Mono.Global home name, _ ) ->
            Names.canonicalToMLIRName home ++ "_" ++ Names.sanitizeName name ++ "_$_" ++ String.fromInt specId

        Just ( Mono.Accessor fieldName, _ ) ->
            "accessor_" ++ Names.sanitizeName fieldName ++ "_$_" ++ String.fromInt specId

        Nothing ->
            "unknown_$_" ++ String.fromInt specId


{-| Add the eco.shadow\_roots unit attribute to a func.func op.
This tells EcoToLLVM to install a shadow root frame for the function's
parameters, protecting them from LLVM's sibling-call TCO across GC.
-}
addShadowRootsAttr : MlirOp -> MlirOp
addShadowRootsAttr op =
    if op.name == "func.func" then
        { op | attrs = Dict.insert "eco.shadow_roots" UnitAttr op.attrs }

    else
        op



-- ====== GENERATE DEFINE ======


{-| The eco.global slot symbol for a memoized thunk. Keyed on the emitted
thunk symbol, which embeds the SpecId — monomorphization splits one source
CAF into several specialized thunks (one per demanded type, more under LSS
keying) with DIFFERENT layouts, so slots are per-SpecId by construction and
must never be shared across specializations. The C++ guard installer
(EcoToLLVMGlobals.cpp installCafMemoGuard) derives the same name.
-}
cafSlotName : String -> String
cafSlotName funcName =
    "__eco_caf$" ++ funcName


{-| Does this nullary value thunk get a memoization slot?

v1 scope (design_docs/caf-memoization-design.md DS5): `!eco.value` ABI
results only — a slot holding a raw scalar (i64 Int, f64, i16 Char) must
never be GC-rooted (the root scan would misread it as a heap address).
Slots are no longer pre-registered (the rooting walk skips `__eco_caf$`;
eco_caf_promote roots on decline, HEAP_036), but the scalar exclusion
stands: a declined scalar slot would still be rooted. Slot value 0 is
the uninitialized sentinel; no valid `!eco.value` word is 0 (pointers are
nonzero, embedded constants are 0x4/0x5/0x6). Trivial single-node bodies
(scalar/string literal, unit) are skipped — the guard would cost more than
the body.
-}
cafMemoQualifies : Ctx.Context -> Mono.MonoExpr -> Mono.MonoType -> Bool
cafMemoQualifies ctx expr monoType =
    ctx.ecoConfig.cafMemo.enabled
        && (Types.monoTypeToAbi monoType == Types.ecoValue)
        && (case expr of
                Mono.MonoClosure _ _ _ ->
                    False

                Mono.MonoLiteral _ _ ->
                    False

                Mono.MonoUnit ->
                    False

                _ ->
                    True
           )


{-| Effect types (Task/Cmd/Sub) are NO LONGER excluded from CAF memoization
(plans/task-purity-and-caf-guard-removal.md, 2026-07-23). The old
`monoTypeHasEffects` guard worked around two native-runtime impurities that
have been FIXED at the source:

1.  The scheduler's Task\_Binding kill-handle install now builds a
    per-execution COPY instead of mutating the shared node (Scheduler.cpp,
    Task immutability).
2.  The last eager kernel tasks now defer their effects to fulfilment
    (MVar new/read/take/put/drop always-binding, Scheduler spawn/kill as
    bindings) — KERNEL\_TASK\_IO\_001 with no partial-eager exemptions.

A Task is an immutable request for IO, fulfilled once per execution — so a
memoized CAF holding one is sound (pinned by MVarSharedNewTaskTest and the
MVar E2E suite).
-}


generateDefine : Ctx.Context -> String -> Bool -> Mono.MonoExpr -> Mono.MonoType -> Maybe Ctx.SretInfo -> Maybe Ctx.PsplitInfo -> ( List MlirOp, Ctx.Context )
generateDefine ctx funcName cafEligible expr monoType maybeSret maybePsplit =
    case expr of
        Mono.MonoClosure closureInfo body _ ->
            generateClosureFunc ctx funcName closureInfo body monoType maybeSret maybePsplit

        _ ->
            -- Value (thunk) - wrap in nullary function
            let
                -- Thunks have no parameters, but still need fresh scope.
                ctxFreshScope : Ctx.Context
                ctxFreshScope =
                    { ctx | nextVar = 0, varMappings = Dict.empty, definedSsaVars = Set.empty }

                exprResult : Expr.ExprResult
                exprResult =
                    Expr.generateExpr ctxFreshScope expr

                retTy =
                    Types.monoTypeToAbi monoType

                region : MlirRegion
                region =
                    if exprResult.isTerminated then
                        -- Expression is a control-flow exit (eco.case, eco.jump).
                        -- The ops already contain the terminator - don't add eco.return.
                        -- IMPORTANT: Do NOT access exprResult.resultVar here - it is meaningless!
                        Ops.mkRegionTerminatedByOps [] exprResult.ops

                    else
                        -- Normal expression - add eco.return with the result value.
                        let
                            -- Handle type mismatch between expression result and expected return type.
                            -- Uses symmetric coercion: primitive <-> !eco.value in either direction.
                            ( coerceOps, finalVar, ctxFinal ) =
                                Expr.coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType retTy

                            ( _, returnOp ) =
                                Ops.ecoReturn ctxFinal finalVar retTy
                        in
                        Ops.mkRegion [] (exprResult.ops ++ coerceOps) returnOp

                ( ctx2, funcOp ) =
                    Ops.funcFunc exprResult.ctx funcName [] retTy region
            in
            if cafEligible && cafMemoQualifies ctx expr monoType then
                -- CAF memoization (plans/caf-memoization-implementation.md):
                -- emit the per-SpecId slot next to the thunk and tag it; the
                -- EcoToLLVM serial post-Stage-2 phase installs the lazy
                -- once-init guard (CGEN_068).
                let
                    ( ctx3, globalOp ) =
                        Ops.ecoGlobal ctx2 (cafSlotName funcName)

                    funcOpTagged =
                        { funcOp | attrs = Dict.insert "eco.caf_memo" UnitAttr funcOp.attrs }
                in
                ( [ globalOp, funcOpTagged ], ctx3 )

            else
                ( [ funcOp ], ctx2 )


{-| Generate closure functions.
For closures with captures: generates both fast clone (captures + params)
and generic clone (Closure\* + params).
For zero-capture closures: generates just the original function.
-}
generateClosureFunc : Ctx.Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> Maybe Ctx.SretInfo -> Maybe Ctx.PsplitInfo -> ( List MlirOp, Ctx.Context )
generateClosureFunc ctx funcName closureInfo body monoType maybeSret maybePsplit =
    let
        hasCaptures =
            not (List.isEmpty closureInfo.captures)
    in
    if hasCaptures then
        -- Two-clone model: fast clone + generic clone (sret selection
        -- excludes captured closures, so maybeSret is Nothing here)
        generateClosureFuncWithClones ctx funcName closureInfo body monoType

    else
        -- Zero captures: single function (original lambda)
        generateClosureFuncSingle ctx funcName closureInfo body monoType maybeSret maybePsplit


{-| Generate a single function for zero-capture closures.
-}
generateClosureFuncSingle : Ctx.Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> Maybe Ctx.SretInfo -> Maybe Ctx.PsplitInfo -> ( List MlirOp, Ctx.Context )
generateClosureFuncSingle ctx funcName closureInfo body monoType maybeSret maybePsplit =
    let
        argPairs : List ( String, MlirType )
        argPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, Types.monoTypeToAbi ty ))
                closureInfo.params

        -- Create fresh varMappings with only function parameters
        freshVarMappings : Dict.Dict String Ctx.VarInfo
        freshVarMappings =
            List.foldl
                (\( name, ty ) acc ->
                    Dict.insert name
                        { ssaVar = "%" ++ name
                        , mlirType = Types.monoTypeToAbi ty
                        }
                        acc
                )
                Dict.empty
                closureInfo.params

        paramSsaVars : List String
        paramSsaVars =
            List.map (\( name, _ ) -> "%" ++ name) closureInfo.params

        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | nextVar = List.length closureInfo.params, varMappings = freshVarMappings }
                |> Ctx.resetDefinedSsaVars paramSsaVars

        exprResult : Expr.ExprResult
        exprResult =
            Expr.generateExpr ctxWithArgs body

        extractedReturnType : Mono.MonoType
        extractedReturnType =
            case monoType of
                Mono.MFunction _ _ _ retType ->
                    retType

                _ ->
                    monoType

        returnType : MlirType
        returnType =
            Types.monoTypeToAbi extractedReturnType

        region : MlirRegion
        region =
            if exprResult.isTerminated then
                Ops.mkRegionTerminatedByOps argPairs exprResult.ops

            else
                let
                    ( coerceOps, finalVar, ctxFinal ) =
                        Expr.coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType returnType

                    ( _, returnOp ) =
                        Ops.ecoReturn ctxFinal finalVar returnType
                in
                Ops.mkRegion argPairs (exprResult.ops ++ coerceOps) returnOp

        ( ctx2, funcOp ) =
            Ops.funcFunc exprResult.ctx funcName argPairs returnType region

        argMonoTypes : List Mono.MonoType
        argMonoTypes =
            List.map Tuple.second closureInfo.params

        funcOpWithLogical =
            LogicalTypes.addLogicalTypesAttr
                ctx2.ecoConfig.logicalTypes.customMaxFields
                ctx2.typeRegistry.ctorShapes
                argMonoTypes
                extractedReturnType
                funcOp
    in
    case ( maybeSret, maybePsplit ) of
        ( Nothing, Just psplitInfo ) ->
            -- U-T1.3.5: emit the $psplit WORKER (scalar params) and the
            -- projecting shim; the funcOp computed above is discarded.
            generatePsplitWorkerAndShim ctx funcName closureInfo body extractedReturnType psplitInfo

        ( Nothing, Nothing ) ->
            ( [ funcOpWithLogical ], ctx2 )

        ( Just sretInfo, _ ) ->
            -- U-T1.3.3: emit the $sret WORKER (real body, multi-result ABI)
            -- and REPLACE the original's body with a thin re-boxing shim so
            -- non-migrated callers and function-as-value uses keep the boxed
            -- ABI. The funcOp computed above is DISCARDED (its full-body ops
            -- were computed; only the worker/shim pair is emitted).
            generateSretWorkerAndShim ctx funcName closureInfo body extractedReturnType sretInfo


{-| U-T1.3.3 result promotion: the `$sret` worker compiles the REAL body
with `sretTailLayout` set (result-spine tuple literals emit the SSA
make-form; result-spine cases declare aggregate results), coerces the
final value to the aggregate (from_heap for boxed fallback shapes),
projects each slot, and multi-returns. The C++ SretFuncOpLowering gives
any multi-result func.func the (slot ptr, args...) -> void ABI. The shim
re-boxes: multi-call the worker, construct the tuple, return.
-}
generateSretWorkerAndShim : Ctx.Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> Ctx.SretInfo -> ( List MlirOp, Ctx.Context )
generateSretWorkerAndShim ctx funcName closureInfo body extractedReturnType sretInfo =
    let
        argPairs : List ( String, MlirType )
        argPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, Types.monoTypeToAbi ty ))
                closureInfo.params

        freshVarMappings : Dict.Dict String Ctx.VarInfo
        freshVarMappings =
            List.foldl
                (\( name, ty ) acc ->
                    Dict.insert name
                        { ssaVar = "%" ++ name
                        , mlirType = Types.monoTypeToAbi ty
                        }
                        acc
                )
                Dict.empty
                closureInfo.params

        paramSsaVars =
            List.map (\( name, _ ) -> "%" ++ name) closureInfo.params

        aggTy =
            Ops.aggTupleType sretInfo.slotTypes

        -- ---- WORKER ----
        ctxWorker : Ctx.Context
        ctxWorker =
            { ctx
                | nextVar = List.length closureInfo.params
                , varMappings = freshVarMappings
                , sretTailLayout = Just sretInfo.layout
            }
                |> Ctx.resetDefinedSsaVars paramSsaVars

        workerRes : Expr.ExprResult
        workerRes =
            Expr.generateExpr ctxWorker body

        ( wCoerceOps, wAggVar, wCtx1 ) =
            if workerRes.isTerminated then
                crash ("generateSretWorkerAndShim: terminated body in sret worker " ++ funcName)

            else
                Expr.coerceResultToType workerRes.ctx workerRes.resultVar workerRes.resultType aggTy

        ( wProjOpsRev, wSlotPairsRev, wCtx2 ) =
            List.foldl
                (\( idx, slotTy ) ( opsAcc, pairsAcc, ctxAcc ) ->
                    let
                        ( pv, ctxF ) =
                            Ctx.freshVar ctxAcc

                        ( ctxP, projOp ) =
                            if sretInfo.layout.arity == 2 then
                                Ops.ecoProjectTuple2Agg ctxF pv idx slotTy ( wAggVar, aggTy )

                            else
                                Ops.ecoProjectTuple3Agg ctxF pv idx slotTy ( wAggVar, aggTy )
                    in
                    ( projOp :: opsAcc, ( pv, slotTy ) :: pairsAcc, ctxP )
                )
                ( [], [], wCtx1 )
                (List.indexedMap Tuple.pair sretInfo.slotTypes)

        ( wCtx3, wReturnOp ) =
            Ops.ecoReturnMulti wCtx2 (List.reverse wSlotPairsRev)

        workerRegion =
            Ops.mkRegion argPairs (workerRes.ops ++ wCoerceOps ++ List.reverse wProjOpsRev) wReturnOp

        ( wCtx4, workerOp ) =
            Ops.funcFuncMulti wCtx3 (funcName ++ "$sret") argPairs sretInfo.slotTypes workerRegion

        -- ---- SHIM ----
        ctxShim : Ctx.Context
        ctxShim =
            { wCtx4
                | nextVar = List.length closureInfo.params
                , varMappings = freshVarMappings
                , sretTailLayout = Nothing
            }
                |> Ctx.resetDefinedSsaVars paramSsaVars

        ( sResultPairsRev, ctxS1 ) =
            List.foldl
                (\slotTy ( acc, c ) ->
                    let
                        ( v, c1 ) =
                            Ctx.freshVar c
                    in
                    ( ( v, slotTy ) :: acc, c1 )
                )
                ( [], ctxShim )
                sretInfo.slotTypes

        sResultPairs =
            List.reverse sResultPairsRev

        ( ctxS2, sCallOp ) =
            Ops.ecoCallNamedMulti ctxS1 [] sResultPairs (funcName ++ "$sret") argPairs

        ( sBoxVar, ctxS3 ) =
            Ctx.freshVar ctxS2

        ( ctxS4, sConstructOp ) =
            case sResultPairs of
                [ a, b ] ->
                    Ops.ecoConstructTuple2 ctxS3 [] sBoxVar a b sretInfo.layout.unboxedBitmap

                [ a, b, c ] ->
                    Ops.ecoConstructTuple3 ctxS3 [] sBoxVar a b c sretInfo.layout.unboxedBitmap

                _ ->
                    crash "generateSretWorkerAndShim: slot arity not 2/3"

        ( _, sReturnOp ) =
            Ops.ecoReturn ctxS4 sBoxVar Types.ecoValue

        shimRegion =
            Ops.mkRegion argPairs [ sCallOp, sConstructOp ] sReturnOp

        ( ctxS5, shimOp ) =
            Ops.funcFunc ctxS4 funcName argPairs Types.ecoValue shimRegion

        argMonoTypes2 =
            List.map Tuple.second closureInfo.params

        shimWithLogical =
            LogicalTypes.addLogicalTypesAttr
                ctxS5.ecoConfig.logicalTypes.customMaxFields
                ctxS5.typeRegistry.ctorShapes
                argMonoTypes2
                extractedReturnType
                shimOp

        ctxOut =
            { ctxS5 | sretTailLayout = Nothing }
    in
    ( [ workerOp, shimWithLogical ], ctxOut )


{-| U-T1.3.5: the `$psplit` worker takes each promoted param's FIELDS as
separate scalar params (unboxed field ⇒ ABI primitive, boxed ⇒ its own
`!eco.value`) — no aggregate type ever appears on the boundary, so the
existing multi-param lowering handles everything (zero C++). The body
binds each promoted param as SLOTS via `ctx.splitAggParams` (the
T1.3.3L consumer machinery; admissibility guarantees every use is a
projection, so materialization is impossible) with the varMapping
REMOVED (bypass ⇒ loud `lookupVar` crash). The shim keeps the original
boxed ABI: heap-project each promoted param's fields and call the
worker.
-}
generatePsplitWorkerAndShim : Ctx.Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> Ctx.PsplitInfo -> ( List MlirOp, Ctx.Context )
generatePsplitWorkerAndShim ctx funcName closureInfo body extractedReturnType psplitInfo =
    let
        returnType =
            Types.monoTypeToAbi extractedReturnType

        paramsWithPlans =
            List.map2 Tuple.pair closureInfo.params psplitInfo.paramPlans

        -- ---- WORKER signature + bindings ----
        workerPieces =
            List.map
                (\( ( name, ty ), mPlan ) ->
                    case mPlan of
                        Just plan ->
                            let
                                slotPairs =
                                    List.indexedMap
                                        (\i slotTy -> ( "%" ++ name ++ "_s" ++ String.fromInt i, slotTy ))
                                        plan.slotTypes
                            in
                            { args = slotPairs
                            , bind = \c -> { c | splitAggParams = Dict.insert name { slots = slotPairs, split = plan.spec } c.splitAggParams }
                            }

                        Nothing ->
                            let
                                abiTy =
                                    Types.monoTypeToAbi ty
                            in
                            { args = [ ( "%" ++ name, abiTy ) ]
                            , bind = Ctx.addVarMapping name ("%" ++ name) abiTy
                            }
                )
                paramsWithPlans

        workerArgPairs =
            List.concatMap .args workerPieces

        ctxWorkerBase =
            { ctx
                | nextVar = List.length workerArgPairs
                , varMappings = Dict.empty
                , splitAggParams = Dict.empty
                , sretTailLayout = Nothing
            }
                |> Ctx.resetDefinedSsaVars (List.map Tuple.first workerArgPairs)

        ctxWorker =
            List.foldl (\piece c -> piece.bind c) ctxWorkerBase workerPieces

        workerRes : Expr.ExprResult
        workerRes =
            Expr.generateExpr ctxWorker body

        workerRegion =
            if workerRes.isTerminated then
                Ops.mkRegionTerminatedByOps workerArgPairs workerRes.ops

            else
                let
                    ( wCoerceOps, wFinalVar, wCtx1 ) =
                        Expr.coerceResultToType workerRes.ctx workerRes.resultVar workerRes.resultType returnType

                    ( _, wReturnOp ) =
                        Ops.ecoReturn wCtx1 wFinalVar returnType
                in
                Ops.mkRegion workerArgPairs (workerRes.ops ++ wCoerceOps) wReturnOp

        wResCtx =
            workerRes.ctx

        ( wCtx2, workerOp ) =
            Ops.funcFunc { wResCtx | splitAggParams = ctx.splitAggParams } (funcName ++ "$psplit") workerArgPairs returnType workerRegion

        -- ---- SHIM: original ABI; project promoted params; call worker ----
        shimArgPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, Types.monoTypeToAbi ty ))
                closureInfo.params

        ctxShim =
            { wCtx2
                | nextVar = List.length closureInfo.params
                , varMappings = Dict.empty
                , splitAggParams = Dict.empty
                , sretTailLayout = Nothing
            }
                |> Ctx.resetDefinedSsaVars (List.map Tuple.first shimArgPairs)

        ( sProjOpsRev, sCallArgsRev, ctxS1 ) =
            List.foldl
                (\( ( name, ty ), mPlan ) ( opsAcc, argsAcc, ctxAcc ) ->
                    case mPlan of
                        Nothing ->
                            ( opsAcc, ( "%" ++ name, Types.monoTypeToAbi ty ) :: argsAcc, ctxAcc )

                        Just plan ->
                            List.foldl
                                (\( idx, slotTy ) ( oa, aa, ca ) ->
                                    let
                                        ( pv, ca1 ) =
                                            Ctx.freshVar ca

                                        ( ca2, projOp ) =
                                            case plan.spec of
                                                Ctx.SplitTuple layout ->
                                                    if layout.arity == 2 then
                                                        Ops.ecoProjectTuple2 ca1 pv idx slotTy ("%" ++ name)

                                                    else
                                                        Ops.ecoProjectTuple3 ca1 pv idx slotTy ("%" ++ name)

                                                Ctx.SplitCtor _ ->
                                                    Ops.ecoProjectCustom ca1 pv idx slotTy ("%" ++ name)
                                    in
                                    ( projOp :: oa, ( pv, slotTy ) :: aa, ca2 )
                                )
                                ( opsAcc, argsAcc, ctxAcc )
                                (List.indexedMap Tuple.pair plan.slotTypes)
                )
                ( [], [], ctxShim )
                paramsWithPlans

        ( sResultVar, ctxS2 ) =
            Ctx.freshVar ctxS1

        ( ctxS3, sCallOp ) =
            Ops.ecoCallNamed ctxS2 [] sResultVar (funcName ++ "$psplit") (List.reverse sCallArgsRev) returnType

        ( _, sReturnOp ) =
            Ops.ecoReturn ctxS3 sResultVar returnType

        shimRegion =
            Ops.mkRegion shimArgPairs (List.reverse sProjOpsRev ++ [ sCallOp ]) sReturnOp

        ( ctxS4, shimOp ) =
            Ops.funcFunc ctxS3 funcName shimArgPairs returnType shimRegion

        shimWithLogical =
            LogicalTypes.addLogicalTypesAttr
                ctxS4.ecoConfig.logicalTypes.customMaxFields
                ctxS4.typeRegistry.ctorShapes
                (List.map Tuple.second closureInfo.params)
                extractedReturnType
                shimOp
    in
    ( [ workerOp, shimWithLogical ], { ctxS4 | splitAggParams = ctx.splitAggParams } )


{-| Generate two clones for closures with captures:

  - Fast clone (funcName$cap): (captures..., params...) -> R
  - Generic clone (funcName$clo): (Closure\*, params...) -> R

The generic clone body loads captures from closure and calls the fast clone.

-}
generateClosureFuncWithClones : Ctx.Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ( List MlirOp, Ctx.Context )
generateClosureFuncWithClones ctx funcName closureInfo body monoType =
    let
        fastCloneName =
            funcName ++ "$cap"

        genericCloneName =
            funcName ++ "$clo"

        -- Capture types for fast clone signature
        captureTypes : List ( String, MlirType )
        captureTypes =
            List.indexedMap
                (\idx ( _, expr, _ ) ->
                    ( "%cap_" ++ String.fromInt idx, Types.monoTypeToAbi (Mono.typeOf expr) )
                )
                closureInfo.captures

        -- Parameter types
        paramPairs : List ( String, MlirType )
        paramPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, Types.monoTypeToAbi ty ))
                closureInfo.params

        -- Fast clone arguments: captures + params
        fastCloneArgs : List ( String, MlirType )
        fastCloneArgs =
            captureTypes ++ paramPairs

        extractedReturnType : Mono.MonoType
        extractedReturnType =
            case monoType of
                Mono.MFunction _ _ _ retType ->
                    retType

                _ ->
                    monoType

        returnType : MlirType
        returnType =
            Types.monoTypeToAbi extractedReturnType

        -- Build var mappings for fast clone: captures use cap_N names,
        -- but the body references original capture names
        captureMappings : Dict.Dict String Ctx.VarInfo
        captureMappings =
            List.foldl
                (\( idx, ( name, expr, _ ) ) acc ->
                    Dict.insert name
                        { ssaVar = "%cap_" ++ String.fromInt idx
                        , mlirType = Types.monoTypeToAbi (Mono.typeOf expr)
                        }
                        acc
                )
                Dict.empty
                (List.indexedMap Tuple.pair closureInfo.captures)

        paramMappings : Dict.Dict String Ctx.VarInfo
        paramMappings =
            List.foldl
                (\( name, ty ) acc ->
                    Dict.insert name
                        { ssaVar = "%" ++ name
                        , mlirType = Types.monoTypeToAbi ty
                        }
                        acc
                )
                Dict.empty
                closureInfo.params

        fastCloneMappings : Dict.Dict String Ctx.VarInfo
        fastCloneMappings =
            Dict.union paramMappings captureMappings

        fastCloneSsaVars : List String
        fastCloneSsaVars =
            List.map Tuple.first fastCloneArgs

        ctxFastClone : Ctx.Context
        ctxFastClone =
            { ctx
                | nextVar = List.length fastCloneArgs
                , varMappings = fastCloneMappings
            }
                |> Ctx.resetDefinedSsaVars fastCloneSsaVars

        exprResult : Expr.ExprResult
        exprResult =
            Expr.generateExpr ctxFastClone body

        fastCloneRegion : MlirRegion
        fastCloneRegion =
            if exprResult.isTerminated then
                Ops.mkRegionTerminatedByOps fastCloneArgs exprResult.ops

            else
                let
                    ( coerceOps, finalVar, _ ) =
                        Expr.coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType returnType

                    ( _, returnOp ) =
                        Ops.ecoReturn exprResult.ctx finalVar returnType
                in
                Ops.mkRegion fastCloneArgs (exprResult.ops ++ coerceOps) returnOp

        ( ctx1, fastCloneOpRaw ) =
            Ops.funcFunc exprResult.ctx fastCloneName fastCloneArgs returnType fastCloneRegion

        -- $cap logical params = capture MonoTypes ++ param MonoTypes
        -- (matches fastCloneArgs = captureTypes ++ paramPairs).
        captureMonoTypes : List Mono.MonoType
        captureMonoTypes =
            List.map (\( _, expr, _ ) -> Mono.typeOf expr) closureInfo.captures

        paramMonoTypes : List Mono.MonoType
        paramMonoTypes =
            List.map Tuple.second closureInfo.params

        fastCloneOp =
            LogicalTypes.addLogicalTypesAttr
                ctx1.ecoConfig.logicalTypes.customMaxFields
                ctx1.typeRegistry.ctorShapes
                (captureMonoTypes ++ paramMonoTypes)
                extractedReturnType
                fastCloneOpRaw

        -- Generic clone: (Closure*, params...) -> R
        -- Body: load captures, call fast clone
        captureSpecs : List ( MlirType, Bool )
        captureSpecs =
            List.map
                (\( _, expr, isUnboxed ) ->
                    ( Types.monoTypeToAbi (Mono.typeOf expr), isUnboxed )
                )
                closureInfo.captures

        ( genericCloneOpRaw, ctx2 ) =
            generateGenericCloneFunc ctx1 genericCloneName fastCloneName captureSpecs paramPairs returnType

        -- $clo logical params: first is the opaque closure pointer
        -- (always !eco.value → "value"), then the Elm params.
        cloLogicalParams : List Mono.MonoType
        cloLogicalParams =
            -- A throwaway MList placeholder won't do — we want "value".
            -- Use MUnit (encoded as "value") for the closure slot since
            -- the encoder treats every non-primitive non-aggregate as
            -- "value".
            Mono.MUnit :: paramMonoTypes

        genericCloneOp =
            LogicalTypes.addLogicalTypesAttr
                ctx2.ecoConfig.logicalTypes.customMaxFields
                ctx2.typeRegistry.ctorShapes
                cloLogicalParams
                extractedReturnType
                genericCloneOpRaw
    in
    ( [ fastCloneOp, genericCloneOp ], ctx2 )


{-| Generate a complete generic clone ($clo) func.func op.
The generic clone takes (Closure\*, params...) and loads captures from the
closure object, then calls the fast clone ($cap).

This is shared by both the top-level closure path (Functions.generateClosureFuncWithClones)
and the inline lambda path (Lambdas.generateLambdaFunc).

-}
generateGenericCloneFunc : Ctx.Context -> String -> String -> List ( MlirType, Bool ) -> List ( String, MlirType ) -> MlirType -> ( MlirOp, Ctx.Context )
generateGenericCloneFunc ctx genericCloneName fastCloneName captureSpecs paramPairs returnType =
    let
        genericCloneArgs =
            ( "%closure", Types.ecoValue ) :: paramPairs

        -- Reset scope for the generic clone's own SSA context.
        -- Entry block args are %closure, %param1..%paramN, so
        -- body SSA values start after those.
        genericCloneArgSsaVars =
            List.map Tuple.first genericCloneArgs

        genericCloneVarMappings =
            List.foldl
                (\( ssaVar, mlirType ) acc ->
                    let
                        -- Strip the leading % from SSA var name for the mapping key
                        name =
                            String.dropLeft 1 ssaVar
                    in
                    Dict.insert name
                        { ssaVar = ssaVar
                        , mlirType = mlirType
                        }
                        acc
                )
                Dict.empty
                genericCloneArgs

        ctxFreshScope =
            { ctx | nextVar = List.length genericCloneArgs, varMappings = genericCloneVarMappings }
                |> Ctx.resetDefinedSsaVars genericCloneArgSsaVars

        ( genericCloneOps, genericCloneResult, ctx1 ) =
            generateGenericCloneBodyFromSpecs ctxFreshScope captureSpecs fastCloneName paramPairs returnType

        genericCloneRegion =
            let
                ( _, returnOp ) =
                    Ops.ecoReturn ctx1 genericCloneResult returnType
            in
            Ops.mkRegion genericCloneArgs genericCloneOps returnOp

        ( ctx2, genericCloneOp ) =
            Ops.funcFunc ctx1 genericCloneName genericCloneArgs returnType genericCloneRegion
    in
    ( genericCloneOp, ctx2 )


{-| Generate the body of the generic clone.
Loads captures from the closure and calls the fast clone.
Takes a list of (MlirType, isUnboxed) specs for each capture.
Returns (ops, resultVar, ctx).
-}
generateGenericCloneBodyFromSpecs : Ctx.Context -> List ( MlirType, Bool ) -> String -> List ( String, MlirType ) -> MlirType -> ( List MlirOp, String, Ctx.Context )
generateGenericCloneBodyFromSpecs ctx captureSpecs fastCloneName paramPairs returnType =
    let
        -- Generate eco.project.closure ops to load each capture
        -- Collect both ops and (var, type) pairs for the call
        ( projectOps, captureVarsWithTypes, ctxAfterProject ) =
            List.foldl
                (\( idx, ( captureType, isUnboxed ) ) ( accOps, accVars, accCtx ) ->
                    let
                        ( captureVar, ctxA ) =
                            Ctx.freshVar accCtx

                        projectAttrs =
                            Dict.fromList
                                [ ( "index", IntAttr Nothing idx )
                                , ( "is_unboxed", BoolAttr isUnboxed )
                                ]

                        ( ctxB, projectOp ) =
                            Ops.mlirOp ctxA "eco.project.closure"
                                |> Ops.opBuilder.withOperands [ "%closure" ]
                                |> Ops.opBuilder.withResults [ ( captureVar, captureType ) ]
                                |> Ops.opBuilder.withAttrs projectAttrs
                                |> Ops.opBuilder.build
                    in
                    ( projectOp :: accOps, ( captureVar, captureType ) :: accVars, ctxB )
                )
                ( [], [], ctx )
                (List.indexedMap Tuple.pair captureSpecs)

        -- Build the call to the fast clone with captures + params
        callArgs =
            List.reverse captureVarsWithTypes ++ paramPairs

        ( resultVar, ctxAfterFresh ) =
            Ctx.freshVar ctxAfterProject

        ( ctxFinal, callOp ) =
            Ops.ecoCallNamed ctxAfterFresh (Expr.emitSafepointHints ctxAfterFresh) resultVar fastCloneName callArgs returnType
    in
    ( List.reverse projectOps ++ [ callOp ], resultVar, ctxFinal )



-- ====== GENERATE TAIL FUNC ======


generateTailFunc : Ctx.Context -> String -> List ( Name.Name, Mono.MonoType ) -> Mono.MonoExpr -> Mono.MonoType -> Maybe Ctx.SretInfo -> ( List MlirOp, Ctx.Context )
generateTailFunc ctx funcName params expr monoType maybeSret =
    let
        -- Function parameters use the original names (%n, %acc, ...) that
        -- the body expression expects.
        funcArgPairs : List ( String, MlirType )
        funcArgPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, Types.monoTypeToAbi ty ))
                params

        -- Create fresh varMappings with function parameters
        freshVarMappings : Dict.Dict String Ctx.VarInfo
        freshVarMappings =
            List.foldl
                (\( name, ty ) acc ->
                    Dict.insert name
                        { ssaVar = "%" ++ name
                        , mlirType = Types.monoTypeToAbi ty
                        }
                        acc
                )
                Dict.empty
                params

        paramSsaVarsTail : List String
        paramSsaVarsTail =
            List.map (\( name, _ ) -> "%" ++ name) params

        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | nextVar = List.length params, varMappings = freshVarMappings, splitAggParams = Dict.empty }
                |> Ctx.resetDefinedSsaVars paramSsaVarsTail

        -- monoType is the full curried function type (e.g., MFunction [MInt] (MFunction [MInt] MInt)).
        -- A NORMAL def consumes every arrow arg, so the ABI return is the final leaf
        -- (sumHelper : Int -> Int -> Int extracts MInt). But a STAGED-RESULT def
        -- (`mk : Int -> (Int -> Int)` written `mk a = \b -> ...`) has FEWER value
        -- params than its type has arrow args; dropping every arg would collapse the
        -- returned CLOSURE to its leaf (mistyping the func as returning i64 and forcing
        -- an unbox of the closure). Drop exactly the consumed params so any residual
        -- arrows survive as the function-typed (closure) result.
        actualReturnType =
            Ctx.residualResultType (List.length params) monoType

        retTy =
            Types.monoTypeToAbi actualReturnType

        -- Use TailRec to compile the function body to scf.while.
        -- U-T1.3.6: a promoted tail func's loop carries DECOMPOSED result
        -- columns and terminates with a multi-operand eco.return — the
        -- $sret worker form.
        ( bodyOps, ctx1 ) =
            TailRec.compileTailFuncToWhile ctxWithArgs funcName funcArgPairs (List.map Tuple.second params) expr retTy maybeSret

        -- The body ops include init ops, scf.while, and eco.return
        -- We need to separate the non-terminator ops from the terminator
        ( bodyNonTermOps, bodyTerminator ) =
            case List.reverse bodyOps of
                term :: rest ->
                    ( List.reverse rest, term )

                [] ->
                    -- This shouldn't happen - compileTailFuncToWhile always returns at least the return op
                    let
                        ( dummyOps, dummyVar, ctxDummy ) =
                            Expr.createDummyValue ctx1 retTy

                        ( _, dummyRetOp ) =
                            Ops.ecoReturn ctxDummy dummyVar retTy
                    in
                    ( dummyOps, dummyRetOp )

        -- Function body region
        funcBodyRegion : MlirRegion
        funcBodyRegion =
            Ops.mkRegion funcArgPairs bodyNonTermOps bodyTerminator

        ( ctx2, funcOp ) =
            Ops.funcFunc ctx1 funcName funcArgPairs retTy funcBodyRegion

        argMonoTypes : List Mono.MonoType
        argMonoTypes =
            List.map Tuple.second params

        funcOpWithLogical =
            LogicalTypes.addLogicalTypesAttr
                ctx2.ecoConfig.logicalTypes.customMaxFields
                ctx2.typeRegistry.ctorShapes
                argMonoTypes
                actualReturnType
                funcOp
    in
    case maybeSret of
        Nothing ->
            ( [ funcOpWithLogical ], ctx2 )

        Just sretInfo ->
            -- U-T1.3.6: the loop body above was compiled in worker form
            -- (multi-result terminal); emit it as `name$sret` and add the
            -- re-boxing shim under the original name. The funcOp built for
            -- the plain path is DISCARDED (funcFuncMulti re-wraps the same
            -- region ops with the multi-result signature).
            let
                ( wCtx, workerOp ) =
                    Ops.funcFuncMulti ctx2 (funcName ++ "$sret") funcArgPairs sretInfo.slotTypes funcBodyRegion

                ctxShim =
                    { wCtx | nextVar = List.length params, varMappings = freshVarMappings, splitAggParams = Dict.empty }
                        |> Ctx.resetDefinedSsaVars paramSsaVarsTail

                ( sResultPairsRev, ctxS1 ) =
                    List.foldl
                        (\slotTy ( acc, c ) ->
                            let
                                ( v, c1 ) =
                                    Ctx.freshVar c
                            in
                            ( ( v, slotTy ) :: acc, c1 )
                        )
                        ( [], ctxShim )
                        sretInfo.slotTypes

                sResultPairs =
                    List.reverse sResultPairsRev

                ( ctxS2, sCallOp ) =
                    Ops.ecoCallNamedMulti ctxS1 [] sResultPairs (funcName ++ "$sret") funcArgPairs

                ( sBoxVar, ctxS3 ) =
                    Ctx.freshVar ctxS2

                ( ctxS4, sConstructOp ) =
                    case sResultPairs of
                        [ a, b ] ->
                            Ops.ecoConstructTuple2 ctxS3 [] sBoxVar a b sretInfo.layout.unboxedBitmap

                        [ a, b, c ] ->
                            Ops.ecoConstructTuple3 ctxS3 [] sBoxVar a b c sretInfo.layout.unboxedBitmap

                        _ ->
                            crash "generateTailFunc: sret slot arity not 2/3"

                ( _, sReturnOp ) =
                    Ops.ecoReturn ctxS4 sBoxVar Types.ecoValue

                shimRegion =
                    Ops.mkRegion funcArgPairs [ sCallOp, sConstructOp ] sReturnOp

                ( ctxS5, shimOp ) =
                    Ops.funcFunc ctxS4 funcName funcArgPairs Types.ecoValue shimRegion

                shimWithLogical =
                    LogicalTypes.addLogicalTypesAttr
                        ctxS5.ecoConfig.logicalTypes.customMaxFields
                        ctxS5.typeRegistry.ctorShapes
                        argMonoTypes
                        actualReturnType
                        shimOp
            in
            ( [ workerOp, shimWithLogical ], ctxS5 )



-- ====== GENERATE CTOR ======


generateCtor : Ctx.Context -> String -> Types.CtorLayout -> Mono.MonoType -> ( Ctx.Context, MlirOp )
generateCtor ctx funcName ctorLayout monoType =
    -- Register the custom type and its constructor for the type graph
    let
        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType monoType ctx

        -- Logical-type attrs for the ctor function. Result is the
        -- Custom type (peeled from any MFunction wrapping); params
        -- are the field MonoTypes.
        ( ctorArgMonoTypes, ctorResultMonoType ) =
            Mono.decomposeFunctionType monoType

        attachLogical : MlirOp -> MlirOp
        attachLogical =
            LogicalTypes.addLogicalTypesAttr
                ctxWithType.ecoConfig.logicalTypes.customMaxFields
                ctxWithType.typeRegistry.ctorShapes
                ctorArgMonoTypes
                ctorResultMonoType

        arity : Int
        arity =
            List.length ctorLayout.fields

        constructorName : Maybe String
        constructorName =
            Just (Name.toElmString ctorLayout.name)
    in
    if arity == 0 then
        -- Nullary constructor - check for well-known constants first
        let
            ( resultVar, ctx1 ) =
                Ctx.freshVar ctxWithType

            -- Check for well-known constants that must use eco.constant
            ( ctx2, valueOp ) =
                case constructorName of
                    Just "Nothing" ->
                        Ops.ecoConstantNothing ctx1 resultVar

                    Just "True" ->
                        Ops.ecoConstantTrue ctx1 resultVar

                    Just "False" ->
                        Ops.ecoConstantFalse ctx1 resultVar

                    _ ->
                        -- Not a well-known constant, use eco.construct.custom.
                        -- Zero-arity constructor in a fresh function scope — no
                        -- in-scope eco.value bindings to track as GC roots.
                        Ops.ecoConstructCustom ctx1 [] resultVar ctorLayout.tag 0 0 [] constructorName

            ( ctx3, returnOp ) =
                Ops.ecoReturn ctx2 resultVar Types.ecoValue

            region : MlirRegion
            region =
                Ops.mkRegion [] [ valueOp ] returnOp

            ( ctxOut, funcOp ) =
                Ops.funcFunc ctx3 funcName [] Types.ecoValue region
        in
        ( ctxOut, attachLogical funcOp )

    else
        -- Constructor with arguments - use eco.construct.custom
        let
            argNames : List String
            argNames =
                List.indexedMap
                    (\i _ -> "%arg" ++ String.fromInt i)
                    ctorLayout.fields

            argTypes : List MlirType
            argTypes =
                List.map
                    (\field ->
                        if field.isUnboxed then
                            Types.monoTypeToAbi field.monoType

                        else
                            Types.ecoValue
                    )
                    ctorLayout.fields

            argPairs : List ( String, MlirType )
            argPairs =
                List.map2 Tuple.pair argNames argTypes

            ctxFreshScope : Ctx.Context
            ctxFreshScope =
                { ctxWithType | nextVar = arity, varMappings = Dict.empty }
                    |> Ctx.resetDefinedSsaVars argNames

            ( resultVar, ctx1 ) =
                Ctx.freshVar ctxFreshScope

            ( ctx2, constructOp ) =
                Ops.ecoConstructCustom ctx1 (Ctx.liveEcoValueVars ctx1) resultVar ctorLayout.tag arity ctorLayout.unboxedBitmap argPairs constructorName

            ( _, returnOp ) =
                Ops.ecoReturn ctx2 resultVar Types.ecoValue

            region : MlirRegion
            region =
                Ops.mkRegion argPairs [ constructOp ] returnOp

            ( ctxOut, funcOp ) =
                Ops.funcFunc ctx2 funcName argPairs Types.ecoValue region
        in
        ( ctxOut, attachLogical funcOp )



-- ====== GENERATE ENUM ======


generateEnum : Ctx.Context -> String -> Int -> Mono.MonoType -> Maybe String -> ( Ctx.Context, MlirOp )
generateEnum ctx funcName tag monoType maybeCtorName =
    let
        -- Register the custom type and its constructor for the type graph
        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType monoType ctx

        ( resultVar, ctx1 ) =
            Ctx.freshVar ctxWithType

        -- Check for well-known constants that must use eco.constant
        ( ctx2, valueOp ) =
            case maybeCtorName of
                Just "True" ->
                    Ops.ecoConstantTrue ctx1 resultVar

                Just "False" ->
                    Ops.ecoConstantFalse ctx1 resultVar

                Just "Nothing" ->
                    Ops.ecoConstantNothing ctx1 resultVar

                _ ->
                    -- Not a well-known constant, use eco.construct.custom.
                    -- Zero-arity constructor in a fresh function scope — no
                    -- in-scope eco.value bindings to track as GC roots.
                    Ops.ecoConstructCustom ctx1 [] resultVar tag 0 0 [] maybeCtorName

        ( ctx3, returnOp ) =
            Ops.ecoReturn ctx2 resultVar Types.ecoValue

        region : MlirRegion
        region =
            Ops.mkRegion [] [ valueOp ] returnOp

        ( _, enumResultMonoType ) =
            Mono.decomposeFunctionType monoType

        ( ctxOut, funcOp ) =
            Ops.funcFunc ctx3 funcName [] Types.ecoValue region

        funcOpWithLogical =
            LogicalTypes.addLogicalTypesAttr
                ctxOut.ecoConfig.logicalTypes.customMaxFields
                ctxOut.typeRegistry.ctorShapes
                []
                enumResultMonoType
                funcOp
    in
    ( ctxOut, funcOpWithLogical )



-- ====== GENERATE EXTERN ======


generateExtern : Ctx.Context -> String -> Mono.MonoType -> ( Ctx.Context, MlirOp )
generateExtern ctx funcName monoType =
    -- Generate an extern declaration with a placeholder body.
    -- MLIR's func.func requires at least one region, so we create a stub body
    -- that returns a default value of the correct type. The actual implementation
    -- will be provided by the runtime linker.
    let
        -- Decompose function type to get argument types and return type
        ( argMonoTypes, resultMonoType ) =
            Mono.decomposeFunctionType monoType

        -- Convert to MLIR types
        argMlirTypes : List MlirType
        argMlirTypes =
            List.map Types.monoTypeToAbi argMonoTypes

        resultMlirType : MlirType
        resultMlirType =
            Types.monoTypeToAbi resultMonoType

        -- Create block argument pairs (arg0, arg1, etc.)
        argPairs : List ( String, MlirType )
        argPairs =
            List.indexedMap (\i ty -> ( "%arg" ++ String.fromInt i, ty )) argMlirTypes

        -- Start fresh var counter after block args
        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | nextVar = List.length argPairs }

        -- Create a stub return value of the correct type
        ( stubVar, ctx1 ) =
            Ctx.freshVar ctxWithArgs

        ( ctx2, stubOp ) =
            generateStubValue ctx1 stubVar resultMonoType resultMlirType

        ( ctx3, returnOp ) =
            Ops.ecoReturn ctx2 stubVar resultMlirType

        region : MlirRegion
        region =
            Ops.mkRegion argPairs [ stubOp ] returnOp

        attrs =
            Dict.fromList
                [ ( "sym_name", StringAttr funcName )
                , ( "sym_visibility", VisibilityAttr Private )
                , ( "function_type"
                  , TypeAttr
                        (FunctionType
                            { inputs = argMlirTypes
                            , results = [ resultMlirType ]
                            }
                        )
                  )
                ]

        ( ctxOut, funcOp ) =
            Ops.mlirOp ctx3 "func.func"
                |> Ops.opBuilder.withRegions [ region ]
                |> Ops.opBuilder.withAttrs attrs
                |> Ops.opBuilder.build

        -- Externs have no Elm-source body — emit "value"-shaped attrs
        -- so cross-spec sees explicit LUnknown shapes (CGEN_065) and
        -- skips specialization.
        funcOpWithLogical =
            LogicalTypes.addLogicalTypesAttr
                ctxOut.ecoConfig.logicalTypes.customMaxFields
                ctxOut.typeRegistry.ctorShapes
                argMonoTypes
                resultMonoType
                funcOp
    in
    ( ctxOut, funcOpWithLogical )


{-| Generate a manager leaf function that calls Elm\_Kernel\_Platform\_leaf.

Effect module `command` and `subscription` globals are compiled to functions
that create Fx\_Leaf bags. This is the MLIR equivalent of the JS backend's
`_Platform_leaf(moduleName)`.

The generated function takes one argument (the effect value) and calls
`Elm_Kernel_Platform_leaf(homeString, value)` to create an Fx\_Leaf bag.

-}
generateManagerLeaf : Ctx.Context -> String -> String -> Mono.MonoType -> ( Ctx.Context, MlirOp )
generateManagerLeaf ctx funcName homeModuleName monoType =
    let
        -- Decompose function type to get argument types and return type
        ( argMonoTypes, resultMonoType ) =
            Mono.decomposeFunctionType monoType

        -- Convert to MLIR types
        argMlirTypes : List MlirType
        argMlirTypes =
            List.map Types.monoTypeToAbi argMonoTypes

        resultMlirType : MlirType
        resultMlirType =
            Types.monoTypeToAbi resultMonoType

        -- Create block argument pairs (arg0, arg1, etc.)
        argPairs : List ( String, MlirType )
        argPairs =
            List.indexedMap (\i ty -> ( "%arg" ++ String.fromInt i, ty )) argMlirTypes

        -- Reset scope for this function's block args
        argSsaVars =
            List.map Tuple.first argPairs

        argVarMappings =
            List.foldl
                (\( ssaVar, mlirType ) acc ->
                    Dict.insert (String.dropLeft 1 ssaVar)
                        { ssaVar = ssaVar, mlirType = mlirType }
                        acc
                )
                Dict.empty
                argPairs

        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | nextVar = List.length argPairs, varMappings = argVarMappings }
                |> Ctx.resetDefinedSsaVars argSsaVars

        -- Create string constant for home module name. eco.string_literal is
        -- not a GCRootCarrier (its allocation call is handled by RS4GC at LLVM
        -- level), so no front-end hint is threaded here.
        ( homeVar, ctx1 ) =
            Ctx.freshVar ctxWithArgs

        ( ctx2, homeOp ) =
            Ops.ecoStringLiteral ctx1 homeVar homeModuleName

        -- Call Elm_Kernel_Platform_leaf(home, arg0) - thread the hint here.
        ( resultVar, ctx3 ) =
            Ctx.freshVar ctx2

        ( ctx4, callOp ) =
            Ops.ecoCallNamed ctx3
                (Expr.emitSafepointHints ctx3)
                resultVar
                "Elm_Kernel_Platform_leaf"
                [ ( homeVar, Types.ecoValue ), ( "%arg0", Types.ecoValue ) ]
                Types.ecoValue

        ( ctx5, returnOp ) =
            Ops.ecoReturn ctx4 resultVar Types.ecoValue

        region : MlirRegion
        region =
            Ops.mkRegion argPairs [ homeOp, callOp ] returnOp

        attrs =
            Dict.fromList
                [ ( "sym_name", StringAttr funcName )
                , ( "sym_visibility", VisibilityAttr Private )
                , ( "function_type"
                  , TypeAttr
                        (FunctionType
                            { inputs = argMlirTypes
                            , results = [ resultMlirType ]
                            }
                        )
                  )
                ]

        ( ctxOut, funcOp ) =
            Ops.mlirOp ctx5 "func.func"
                |> Ops.opBuilder.withRegions [ region ]
                |> Ops.opBuilder.withAttrs attrs
                |> Ops.opBuilder.build

        funcOpWithLogical =
            LogicalTypes.addLogicalTypesAttr
                ctxOut.ecoConfig.logicalTypes.customMaxFields
                ctxOut.typeRegistry.ctorShapes
                argMonoTypes
                resultMonoType
                funcOp
    in
    ( ctxOut, funcOpWithLogical )


{-| Generate a stub value of the given type for extern function bodies.
-}
generateStubValue : Ctx.Context -> String -> Mono.MonoType -> MlirType -> ( Ctx.Context, MlirOp )
generateStubValue ctx resultVar _ mlirType =
    -- Use mlirType instead of monoType because mlirType represents the actual
    -- concrete type after monomorphization, which may be a primitive even when
    -- the monoType is a type variable.
    case mlirType of
        I64 ->
            Ops.arithConstantInt ctx resultVar 0

        F64 ->
            Ops.arithConstantFloat ctx resultVar 0.0

        I1 ->
            Ops.arithConstantBool ctx resultVar False

        I16 ->
            Ops.arithConstantChar ctx resultVar 0

        _ ->
            -- For all other types (EcoValue, etc.), return Unit
            Ops.ecoConstantUnit ctx resultVar


{-| Generate a kernel function declaration with a stub body.
The stub body is required by MLIR's func dialect (func.func must have a region).
The stub will be replaced with an external declaration during lowering to LLVM.
We mark it with an `is_kernel` attribute so the lowering pass can identify it.
-}
generateKernelDecl : Ctx.Context -> Ctx.KernelDeclInfo -> ( Ctx.Context, MlirOp )
generateKernelDecl ctx info =
    let
        argMlirTypes : List MlirType
        argMlirTypes =
            info.abiArgTypes

        resultMlirType : MlirType
        resultMlirType =
            info.abiResultType

        -- Create block argument pairs (arg0, arg1, etc.)
        argPairs : List ( String, MlirType )
        argPairs =
            List.indexedMap (\i ty -> ( "%arg" ++ String.fromInt i, ty )) argMlirTypes

        -- Start fresh var counter after block args
        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | nextVar = List.length argPairs }

        -- Create a stub return value of the correct type
        ( stubVar, ctx1 ) =
            Ctx.freshVar ctxWithArgs

        -- Generate stub value based on MLIR type
        ( ctx2, stubOp ) =
            generateStubValueFromMlirType ctx1 stubVar resultMlirType

        ( ctx3, returnOp ) =
            Ops.ecoReturn ctx2 stubVar resultMlirType

        region : MlirRegion
        region =
            Ops.mkRegion argPairs [ stubOp ] returnOp

        attrs =
            Dict.fromList
                [ ( "sym_name", StringAttr info.symbolName )
                , ( "sym_visibility", VisibilityAttr Private )
                , ( "is_kernel", BoolAttr True ) -- Mark as kernel for lowering
                , ( "function_type"
                  , TypeAttr
                        (FunctionType
                            { inputs = argMlirTypes
                            , results = [ resultMlirType ]
                            }
                        )
                  )
                ]

        ( ctxOut, funcOp ) =
            Ops.mlirOp ctx3 "func.func"
                |> Ops.opBuilder.withRegions [ region ]
                |> Ops.opBuilder.withAttrs attrs
                |> Ops.opBuilder.build

        -- Kernel decls carry no MonoType; fall back to ABI-only
        -- encoding so the attrs are present but mark all aggregate
        -- slots as opaque (CGEN_065 absent-or-LUnknown clause).
        funcOpWithLogical =
            LogicalTypes.addLogicalTypesAttrUnknown
                argMlirTypes
                resultMlirType
                funcOp
    in
    ( ctxOut, funcOpWithLogical )


{-| Generate a stub value for kernel declaration bodies, based on MLIR type.
-}
generateStubValueFromMlirType : Ctx.Context -> String -> MlirType -> ( Ctx.Context, MlirOp )
generateStubValueFromMlirType ctx resultVar mlirType =
    case mlirType of
        I64 ->
            Ops.arithConstantInt ctx resultVar 0

        F64 ->
            Ops.arithConstantFloat ctx resultVar 0.0

        I1 ->
            Ops.arithConstantBool ctx resultVar False

        I16 ->
            Ops.arithConstantChar ctx resultVar 0

        _ ->
            -- For all other types (EcoValue, etc.), return Unit
            Ops.ecoConstantUnit ctx resultVar
