module Compiler.Generate.MLIR.Functions exposing (generateMainEntry, generateNode, generateKernelDecl)

{-| Every top-level thing a monomorphized program contains becomes one or more
MLIR `func.func` ops, and this module is where each of them is built.

A _node_ is one specialization of a top-level definition: a function or value,
a tail-recursive function, a constructor, an enum constructor, an extern, an
effect-manager leaf or a port. `generateNode` turns one node into its function
ops. A node's name is `<Module>_<name>_$_<specId>` (`accessor_<field>_$_<specId>`
for a record accessor, `unknown_$_<specId>` when the registry has no key), so
a reference to a specialization can be named from its SpecId alone. A capture
clone or worker function appends `$cap`, `$sret` or `$psplit` to that name.
`generateNode` clears `varMappings`, `definedSsaVars`, `sretTailLayout` and
`splitAggParams` before returning the context, so the next node cannot see this
node's variables.

A few terms recur. A _thunk_ is the nullary function a top-level value compiles
to. _CAF memoisation_ gives a thunk an `eco.global` slot, its _CAF slot_, and
the attribute `eco.caf_memo`, so that lowering can make it compute its value
once. A function with a promoted result or promoted parameters is emitted as a
_worker_ with the promoted ABI (`$sret` returns each field of its tuple result
separately; `$psplit` takes promoted parameters as their fields) and a _shim_
under the original name that keeps the boxed ABI by calling the worker. A
closure with captures is emitted as its _fast clone_, `$cap`, which takes the
captures followed by the parameters.

Two rewrites change a node's body before or instead of compiling it. A
`List.map` specialization licensed by `Compiler.GlobalOpt.MapTemplate` becomes a
single `eco.list.map` op. When chunked lists are enabled, a _shunt_ replaces
the body of a capture-free elm/core `List.reverse`, `append`, `concat`, `take`
or `drop` specialization by a direct call to the kernel of the same name.

The module also builds the program entry point `@main` with its registration
preamble `@__eco_register_ports`, and the stub declarations of kernel
functions.

@docs generateMainEntry, generateNode, generateKernelDecl

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.CtorTag as CtorTag
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Expr as Expr
import Compiler.Generate.MLIR.LogicalTypes as LogicalTypes
import Compiler.Generate.MLIR.Names as Names
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.TailRec as TailRec
import Compiler.Generate.MLIR.Types as Types
import Compiler.GlobalOpt.MapTemplate as MapTemplate
import Compiler.Monomorphize.Registry as Registry
import Compiler.Reporting.Annotation as A
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirRegion, MlirType(..), Visibility(..))
import Set
import Utils.Crash exposing (crash)



-- ====== GENERATE MAIN ENTRY ======


{-| Builds the program entry point `@main`, which calls the function of the
main specialization and returns its result, together with the
`@__eco_register_ports` function that `@main` calls first when there is
anything to register.

`managers` is the set of home modules of the eco/system effect managers to
register. Under chunked lists, `@main` carries the `eco.list_chunks` attribute,
which tells lowering that the program uses chunked lists. The returned
context records the registration kernels as kernel declarations.

-}
generateMainEntry : Ctx.Context -> List Mono.PortRegistration -> Maybe Mono.SpecId -> Set.Set String -> Mono.MainInfo -> ( List MlirOp, Ctx.Context )
generateMainEntry ctx ports flagsDecoder managers mainInfo =
    case mainInfo of
        Mono.StaticMain mainSpecId ->
            let
                ( portFnOps, ctxPorts ) =
                    generateRegisterPorts ctx ports flagsDecoder managers

                ctxMain =
                    { ctxPorts | nextVar = 0, varMappings = Dict.empty, definedSsaVars = Set.empty }

                -- Registration must happen before the program's main runs.
                ( preambleOps, ctx0 ) =
                    if List.isEmpty portFnOps then
                        ( [], ctxMain )

                    else
                        let
                            ( regVar, ctxA ) =
                                Ctx.freshVar ctxMain

                            ( ctxB, regCallOp ) =
                                Ops.ecoCallNamed ctxA regVar "__eco_register_ports" [] Types.ecoValue
                        in
                        ( [ regCallOp ], ctxB )

                ( callVar, ctx1 ) =
                    Ctx.freshVar ctx0

                mainFuncName : String
                mainFuncName =
                    specIdToFuncName ctx.registry mainSpecId

                ( ctx2, callOp ) =
                    Ops.ecoCallNamed ctx1 callVar mainFuncName [] Types.ecoValue

                ( ctx3, returnOp ) =
                    Ops.ecoReturn ctx2 callVar Types.ecoValue

                region : MlirRegion
                region =
                    Ops.mkRegion [] (preambleOps ++ [ callOp ]) returnOp

                ( ctx4, mainOp0 ) =
                    Ops.funcFunc ctx3 "main" [] Types.ecoValue region

                mainOp =
                    if ctx.ecoConfig.list.chunks then
                        { mainOp0 | attrs = Dict.insert "eco.list_chunks" UnitAttr mainOp0.attrs }

                    else
                        mainOp0
            in
            ( portFnOps ++ [ mainOp ], ctx4 )


{-| Builds the `@__eco_register_ports` function, which registers with the
runtime everything it must know before the program starts, and returns `unit`.

Its calls come in this order. First one call per home in `managers`, in set
order, to that manager's `ecoSystemRegisterManagerSymbol`. Then, when there is a
flags decoder, a call to its thunk and to
`Elm_Kernel_Platform_registerFlagsDecoder` with the decoder. Then, for each port
in order, a call to `Elm_Kernel_Platform_registerIncomingPort` with the port's
name and decoder (obtained by calling the decoder thunk named by
`decoderSpecId`) for an incoming port that has a decoder, and to
`Elm_Kernel_Platform_registerOutgoingPort` with the name for any other port.

Returns no ops, and the context unchanged, when there are no ports, no flags
decoder and no managers.

-}
generateRegisterPorts : Ctx.Context -> List Mono.PortRegistration -> Maybe Mono.SpecId -> Set.Set String -> ( List MlirOp, Ctx.Context )
generateRegisterPorts ctx0 ports flagsDecoder managers =
    if List.isEmpty ports && flagsDecoder == Nothing && Set.isEmpty managers then
        ( [], ctx0 )

    else
        let
            ctxClean =
                { ctx0 | nextVar = 0, varMappings = Dict.empty, definedSsaVars = Set.empty }

            hasIncoming =
                List.any .incoming ports

            hasOutgoing =
                List.any (\p -> not p.incoming) ports

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

            ( managerRevOps, ctxAfterManagers ) =
                Set.foldl
                    (\home ( accOps, c ) ->
                        let
                            symbol =
                                ecoSystemRegisterManagerSymbol home

                            ( resultVar, c1 ) =
                                Ctx.freshVar (Ctx.registerKernelCall c symbol [] Types.ecoValue)

                            ( c2, registerOp ) =
                                Ops.ecoCallNamed c1 resultVar symbol [] Types.ecoValue
                        in
                        ( registerOp :: accOps, c2 )
                    )
                    ( [], ctxKernels )
                    managers

            ( flagsRevOps, ctxAfterFlags ) =
                case flagsDecoder of
                    Nothing ->
                        ( [], ctxAfterManagers )

                    Just decoderSpecId ->
                        let
                            ( decoderVar, c1 ) =
                                Ctx.freshVar ctxAfterManagers

                            ( c2, decoderCallOp ) =
                                Ops.ecoCallNamed c1
                                    decoderVar
                                    (specIdToFuncName c1.registry decoderSpecId)
                                    []
                                    Types.ecoValue

                            ( resultVar, c3 ) =
                                Ctx.freshVar c2

                            ( c4, registerOp ) =
                                Ops.ecoCallNamed c3
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
                                            decoderVar
                                            (specIdToFuncName c3.registry decoderSpecId)
                                            []
                                            Types.ecoValue

                                    ( resultVar, c5 ) =
                                        Ctx.freshVar c4

                                    ( c6, registerOp ) =
                                        Ops.ecoCallNamed c5
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
                Ops.mkRegion [] (List.reverse (revOps ++ flagsRevOps ++ managerRevOps) ++ [ unitOp ]) returnOp

            ( ctxF, funcOp ) =
                Ops.funcFunc ctxU3 "__eco_register_ports" [] Types.ecoValue region
        in
        ( [ funcOp ], ctxF )


{-| Returns the symbol of the function that registers the eco/system effect
manager of module `home`: `Eco_System_registerManager_` followed by `home` with
every `.` replaced by `_`.
-}
ecoSystemRegisterManagerSymbol : String -> String
ecoSystemRegisterManagerSymbol home =
    "Eco_System_registerManager_" ++ String.replace "." "_" home


{-| Returns `ctx` with `home` added to `ecoSystemManagers` when the manager leaf
`specId` is a global of a module in package eco/system, and `ctx` unchanged
otherwise. Being a set, it holds a home once however many leaf specializations
reach it.
-}
recordEcoSystemManager : Mono.SpecId -> String -> Ctx.Context -> Ctx.Context
recordEcoSystemManager specId home ctx =
    case Registry.lookupSpecKey specId ctx.registry of
        Just ( Mono.Global (ModuleName.Canonical pkg _) _, _ ) ->
            if pkg == Pkg.ecoSystem then
                { ctx | ecoSystemManagers = Set.insert home ctx.ecoSystemManagers }

            else
                ctx

        _ ->
            ctx



-- ====== LIST COMBINATOR SHUNTS (chunked lists) ======


{-| The elm/core `List` functions a shunt may replace, each with the number of
parameters its specialization must take. Each is replaced by a call to the
`List` kernel function of the same name.
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


{-| Returns `node` with its body replaced by a direct kernel call, when chunked
lists are enabled and `specId` is a specialization of one of the
`listShuntKernels` functions of elm/core's `List` module. The function is
recognised by the registry's key for `specId`, so a program's own function of
the same name is never rewritten. Otherwise, and for any node `listShuntNode`
declines, `node` is returned unchanged.
-}
listChunksShunt : Ctx.Context -> Mono.SpecId -> Mono.MonoNode -> Mono.MonoNode
listChunksShunt ctx specId node =
    if not ctx.ecoConfig.list.chunks then
        node

    else
        case Registry.lookupSpecKey specId ctx.registry of
            Just ( Mono.Global (ModuleName.Canonical pkg "List") name, _ ) ->
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


{-| Returns `node` with its body replaced by a call to the `List` kernel
`kernelName`, when `node` is a `MonoDefine` of a closure with no captures and
exactly `arity` parameters, and `node` unchanged otherwise. A tail-recursive
node is never rewritten.
-}
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


{-| Builds a saturated call of the `List` kernel `kernelName` on `params`,
returning `resultTy`. The call kind is `CallDirectFlat`, so each argument is
passed at the ABI of its own type; an `Int` argument, for example, is passed
unboxed.
-}
listShuntCall : Name.Name -> List ( Name.Name, Mono.MonoType ) -> Mono.MonoType -> Mono.MonoExpr
listShuntCall kernelName params resultTy =
    let
        kernelTy : Mono.MonoType
        kernelTy =
            Mono.mFunction Mono.topSynth (List.map Tuple.second params) resultTy

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


{-| Builds the ops for the node `specId`, after applying the list shunt.

Most nodes give one function. A promoted function gives a worker and a shim,
and a memoised thunk gives its CAF slot and the thunk.

Every global named `main`, in whichever module, has its CAF memoisation
removed and its functions marked `eco.shadow_roots`, which asks lowering to
keep the function's parameters in a shadow root frame across collections. A
memoised thunk returns early once its value is computed, which would skip the
balancing of that frame.

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

        isMainEntry =
            case Registry.lookupSpecKey specId ctx.registry of
                Just ( Mono.Global _ name, _ ) ->
                    name == "main"

                _ ->
                    False

        finalOps =
            if isMainEntry then
                ops
                    |> List.filter (\op -> op.name /= "eco.global")
                    |> List.map (\op -> { op | attrs = Dict.remove "eco.caf_memo" op.attrs })
                    |> List.map addShadowRootsAttr

            else
                ops

        -- The next node's functions must not see this node's variables.
        cleanCtx =
            { dirtyCtx | varMappings = Dict.empty, definedSsaVars = Set.empty, sretTailLayout = Nothing, splitAggParams = Dict.empty }
    in
    ( finalOps, cleanCtx )


{-| Builds the ops for `node`, named `funcName`, choosing the generator by
the kind of node.

A `List.map` specialization with a template licence is compiled as an
`eco.list.map` op when its closure has the expected two parameters, and as an
ordinary definition otherwise. Ports are compiled as definitions that are never
memoised.

-}
generateNodeInner : Ctx.Context -> String -> Mono.SpecId -> Mono.MonoNode -> ( List MlirOp, Ctx.Context )
generateNodeInner ctx funcName specId node =
    case node of
        Mono.MonoDefine expr monoType ->
            case ( MapTemplate.lookup specId ctx.mapTemplates, expr ) of
                ( Just info, Mono.MonoClosure closureInfo _ _ ) ->
                    case generateMapTemplateBody ctx funcName info closureInfo monoType of
                        Just result ->
                            result

                        Nothing ->
                            generateDefine ctx funcName True expr monoType (Dict.get specId ctx.sretPromoted) (Dict.get specId ctx.psplitPromoted)

                _ ->
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
                maybeCtor : Maybe ( ModuleName.Canonical, String )
                maybeCtor =
                    case Registry.lookupSpecKey specId ctx.registry of
                        Just ( Mono.Global home ctorName, _ ) ->
                            Just ( home, Name.toElmString ctorName )

                        Just ( Mono.Accessor _, _ ) ->
                            Nothing

                        Nothing ->
                            Nothing

                ( ctx1, op ) =
                    generateEnum ctx funcName tag monoType maybeCtor
            in
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
                    generateManagerLeaf (recordEcoSystemManager specId homeModuleName ctx) funcName homeModuleName monoType
            in
            ( [ op ], ctx1 )

        Mono.MonoPortIncoming expr monoType ->
            generateDefine ctx funcName False expr monoType Nothing Nothing

        Mono.MonoPortOutgoing expr monoType ->
            generateDefine ctx funcName False expr monoType Nothing Nothing


{-| Returns the function name of the specialization `specId`:
`<Module>_<name>_$_<specId>` for a global, `accessor_<field>_$_<specId>` for a
record accessor, and `unknown_$_<specId>` when `registry` has no key for it.
-}
specIdToFuncName : Mono.SpecializationRegistry -> Mono.SpecId -> String
specIdToFuncName registry specId =
    case Registry.lookupSpecKey specId registry of
        Just ( Mono.Global home name, _ ) ->
            Names.canonicalToMLIRName home ++ "_" ++ Names.sanitizeName name ++ "_$_" ++ String.fromInt specId

        Just ( Mono.Accessor fieldName, _ ) ->
            "accessor_" ++ Names.sanitizeName fieldName ++ "_$_" ++ String.fromInt specId

        Nothing ->
            "unknown_$_" ++ String.fromInt specId


{-| Returns `op` with the `eco.shadow_roots` attribute when it is a
`func.func`, and unchanged otherwise.
-}
addShadowRootsAttr : MlirOp -> MlirOp
addShadowRootsAttr op =
    if op.name == "func.func" then
        { op | attrs = Dict.insert "eco.shadow_roots" UnitAttr op.attrs }

    else
        op



-- ====== GENERATE DEFINE ======


{-| Returns the name of the CAF slot of the thunk `funcName`. The thunk's name
contains its SpecId, so each specialization of one source value has its own
slot. Lowering derives the slot from the thunk's name the same way, so the two
must agree.
-}
cafSlotName : String -> String
cafSlotName funcName =
    "__eco_caf$" ++ funcName


{-| Returns whether the thunk for the value `expr` of type `monoType` is
memoised: CAF memoisation must be enabled, the value's ABI type must be
`!eco.value`, and `expr` must not be a closure, a literal or `unit`.

A slot is only ever given to a value whose ABI type is `!eco.value`, because a
rooted slot holding a raw scalar would be scanned as a pointer. A literal or
`unit` costs less to produce than the check of a slot would.

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


{-| Builds the functions of the definition `funcName` with body `expr`.

A closure is compiled by `generateClosureFunc`, with its promotions. Any other
value becomes a thunk; when `cafEligible` is `True` and `cafMemoQualifies`
holds, the thunk is marked `eco.caf_memo` and preceded by its CAF slot. Values
of type `Task`, `Cmd` and `Sub` are memoised like any other: a `Task` is a
description of work, not the work, so sharing one value is safe.

-}
generateDefine : Ctx.Context -> String -> Bool -> Mono.MonoExpr -> Mono.MonoType -> Maybe Ctx.SretInfo -> Maybe Ctx.PsplitInfo -> ( List MlirOp, Ctx.Context )
generateDefine ctx funcName cafEligible expr monoType maybeSret maybePsplit =
    case expr of
        Mono.MonoClosure closureInfo body _ ->
            generateClosureFunc ctx funcName closureInfo body monoType maybeSret maybePsplit

        _ ->
            let
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
                        -- The ops end in their own terminator, and resultVar means nothing.
                        Ops.mkRegionTerminatedByOps [] exprResult.ops

                    else
                        let
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
                let
                    ( ctx3, globalOp ) =
                        Ops.ecoGlobal ctx2 (cafSlotName funcName)

                    funcOpTagged =
                        { funcOp | attrs = Dict.insert "eco.caf_memo" UnitAttr funcOp.attrs }
                in
                ( [ globalOp, funcOpTagged ], ctx3 )

            else
                ( [ funcOp ], ctx2 )


{-| Builds the functions of the closure definition `funcName`: its fast clone
when the closure has captures, and otherwise the function itself with any
`$sret` or `$psplit` promotion in `maybeSret` and `maybePsplit`. The
promotions are ignored for a closure with captures.
-}
generateClosureFunc : Ctx.Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> Maybe Ctx.SretInfo -> Maybe Ctx.PsplitInfo -> ( List MlirOp, Ctx.Context )
generateClosureFunc ctx funcName closureInfo body monoType maybeSret maybePsplit =
    let
        hasCaptures =
            not (List.isEmpty closureInfo.captures)
    in
    if hasCaptures then
        generateClosureFuncWithCaptures ctx funcName closureInfo body monoType

    else
        generateClosureFuncSingle ctx funcName closureInfo body monoType maybeSret maybePsplit


{-| Builds the function `funcName` for a closure with no captures, taking the
closure's parameters and returning the result of `monoType` at its ABI type.

With `maybeSret` it instead returns a `$sret` worker and a shim, and with only
`maybePsplit` a `$psplit` worker and a shim; `maybeSret` wins when both are
given.

-}
generateClosureFuncSingle : Ctx.Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> Maybe Ctx.SretInfo -> Maybe Ctx.PsplitInfo -> ( List MlirOp, Ctx.Context )
generateClosureFuncSingle ctx funcName closureInfo body monoType maybeSret maybePsplit =
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
            generatePsplitWorkerAndShim ctx funcName closureInfo body extractedReturnType psplitInfo

        ( Nothing, Nothing ) ->
            ( [ funcOpWithLogical ], ctx2 )

        ( Just sretInfo, _ ) ->
            generateSretWorkerAndShim ctx funcName closureInfo body extractedReturnType sretInfo


{-| Builds the function `funcName` of a licensed `List.map` specialization as
one `eco.list.map` op over the list and the callback, in place of the body.
Returns `Nothing` when the closure does not have exactly two parameters, the
callback and then the list.

The callback's captures, whose types the licence `info` records, are projected
out of the callback once, before the op, and passed to it as operands. The op
names the callee function in its `callee` attribute: the lambda's own name when
it has no captures and its `$cap` fast clone when it has some, or the function
of a specialization. A callback the licence calls generically gets no `callee`
attribute.

-}
generateMapTemplateBody : Ctx.Context -> String -> MapTemplate.Info -> Mono.ClosureInfo -> Mono.MonoType -> Maybe ( List MlirOp, Ctx.Context )
generateMapTemplateBody ctx funcName info closureInfo monoType =
    case closureInfo.params of
        [ ( callbackName, callbackMonoTy ), ( listName, listMonoTy ) ] ->
            let
                argPairs : List ( String, MlirType )
                argPairs =
                    [ ( "%" ++ callbackName, Types.monoTypeToAbi callbackMonoTy )
                    , ( "%" ++ listName, Types.monoTypeToAbi listMonoTy )
                    ]

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

                ctx0 : Ctx.Context
                ctx0 =
                    { ctx | nextVar = 2, varMappings = Dict.empty }
                        |> Ctx.resetDefinedSsaVars
                            [ "%" ++ callbackName, "%" ++ listName ]

                captureAbiTypes : List MlirType
                captureAbiTypes =
                    case info.callee of
                        MapTemplate.CalleeLambda _ captureTypes ->
                            List.map Types.monoTypeToAbi captureTypes

                        MapTemplate.CalleeSpec _ ->
                            []

                        MapTemplate.CalleeGeneric ->
                            []

                ( projectOpsRev, captureVarsRev, ctxProj ) =
                    List.foldl
                        (\( idx, capMlirTy ) ( accOps, accVars, accCtx ) ->
                            let
                                ( capVar, ctxA ) =
                                    Ctx.freshVar accCtx

                                ( ctxB, projectOp ) =
                                    Ops.mlirOp ctxA "eco.project.closure"
                                        |> Ops.opBuilder.withOperands [ "%" ++ callbackName ]
                                        |> Ops.opBuilder.withResults [ ( capVar, capMlirTy ) ]
                                        |> Ops.opBuilder.withAttrs
                                            (Dict.fromList
                                                [ ( "index", IntAttr Nothing idx )
                                                , ( "is_unboxed"
                                                  , BoolAttr (not (Types.isEcoValueType capMlirTy))
                                                  )
                                                ]
                                            )
                                        |> Ops.opBuilder.build
                            in
                            ( projectOp :: accOps, ( capVar, capMlirTy ) :: accVars, ctxB )
                        )
                        ( [], [], ctx0 )
                        (List.indexedMap Tuple.pair captureAbiTypes)

                captureVars : List ( String, MlirType )
                captureVars =
                    List.reverse captureVarsRev

                calleeSymbol : String
                calleeSymbol =
                    case info.callee of
                        MapTemplate.CalleeLambda lambdaId captureTypes ->
                            if List.isEmpty captureTypes then
                                Expr.lambdaIdToString lambdaId

                            else
                                Expr.lambdaIdToString lambdaId ++ "$cap"

                        MapTemplate.CalleeSpec calleeSpecId ->
                            specIdToFuncName ctx.registry calleeSpecId

                        MapTemplate.CalleeGeneric ->
                            -- Unused: calleeAttrs omits the attribute.
                            ""

                -- The op's verifier accepts a missing callee only with no captures.
                calleeAttrs : List ( String, MlirAttr )
                calleeAttrs =
                    case info.callee of
                        MapTemplate.CalleeGeneric ->
                            []

                        _ ->
                            [ ( "callee", SymbolRefAttr calleeSymbol ) ]

                ( resultVar, ctxRes ) =
                    Ctx.freshVar ctxProj

                ( ctxOp, mapOp ) =
                    Ops.mlirOp ctxRes "eco.list.map"
                        |> Ops.opBuilder.withOperands
                            (("%" ++ listName)
                                :: ("%" ++ callbackName)
                                :: List.map Tuple.first captureVars
                            )
                        |> Ops.opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
                        |> Ops.opBuilder.withAttrs
                            (Dict.fromList
                                (calleeAttrs
                                    ++ [ ( "in_kind", IntAttr Nothing info.inKind )
                                       , ( "out_kind", IntAttr Nothing info.outKind )
                                       , ( "_operand_types"
                                         , ArrayAttr Nothing
                                            (List.map TypeAttr
                                                (Types.ecoValue
                                                    :: Types.ecoValue
                                                    :: List.map Tuple.second captureVars
                                                )
                                            )
                                         )
                                       ]
                                )
                            )
                        |> Ops.opBuilder.build

                ( coerceOps, finalVar, ctxCoerce ) =
                    Expr.coerceResultToType ctxOp resultVar Types.ecoValue returnType

                ( ctxRet, returnOp ) =
                    Ops.ecoReturn ctxCoerce finalVar returnType

                region : MlirRegion
                region =
                    Ops.mkRegion argPairs
                        (List.reverse projectOpsRev ++ [ mapOp ] ++ coerceOps)
                        returnOp

                ( ctxFunc, funcOp ) =
                    Ops.funcFunc ctxRet funcName argPairs returnType region

                funcOpWithLogical =
                    LogicalTypes.addLogicalTypesAttr
                        ctxFunc.ecoConfig.logicalTypes.customMaxFields
                        ctxFunc.typeRegistry.ctorShapes
                        [ callbackMonoTy, listMonoTy ]
                        extractedReturnType
                        funcOp
            in
            Just ( [ funcOpWithLogical ], ctxFunc )

        _ ->
            Nothing


{-| Builds the `$sret` worker and the shim of the closure `funcName`, whose
result is the tuple `sretInfo` describes.

The worker `funcName$sret` compiles `body` with `sretTailLayout` set, so the
tuples on the result's path are built as values rather than on the heap. It
converts the result to the tuple aggregate, projects each field and returns
the fields as separate results. The shim `funcName` takes the same parameters,
calls the worker, builds the boxed tuple from its results and returns it.
Crashes when `body` ends in its own terminator, or when the tuple does not have
two or three fields.

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
            Ops.ecoCallNamedMulti ctxS1 sResultPairs (funcName ++ "$sret") argPairs

        ( sBoxVar, ctxS3 ) =
            Ctx.freshVar ctxS2

        ( ctxS4, sConstructOp ) =
            case sResultPairs of
                [ a, b ] ->
                    Ops.ecoConstructTuple2 ctxS3 sBoxVar a b sretInfo.layout.unboxedBitmap

                [ a, b, c ] ->
                    Ops.ecoConstructTuple3 ctxS3 sBoxVar a b c sretInfo.layout.unboxedBitmap

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


{-| Builds the `$psplit` worker and the shim of the closure `funcName`, whose
promoted parameters `psplitInfo` describes.

The worker `funcName$psplit` takes each promoted parameter as one parameter
per field, named `<param>_s<index>`, at the type the plan gives the field, and
every other parameter as it is. In the body, a promoted parameter is bound as
its fields in `splitAggParams` and has no variable of its own. The shim
`funcName` takes the original parameters, projects the fields of each promoted
one, calls the worker and returns its result.

-}
generatePsplitWorkerAndShim : Ctx.Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> Ctx.PsplitInfo -> ( List MlirOp, Ctx.Context )
generatePsplitWorkerAndShim ctx funcName closureInfo body extractedReturnType psplitInfo =
    let
        returnType =
            Types.monoTypeToAbi extractedReturnType

        paramsWithPlans =
            List.map2 Tuple.pair closureInfo.params psplitInfo.paramPlans

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
            Ops.ecoCallNamed ctxS2 sResultVar (funcName ++ "$psplit") (List.reverse sCallArgsRev) returnType

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


{-| Builds the fast clone `funcName$cap` of a closure with captures: a function
taking the captures, as `%cap_<index>`, followed by the parameters, and
returning the closure's result. Within the body each capture's name refers to
its `%cap_<index>` parameter.
-}
generateClosureFuncWithCaptures : Ctx.Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ( List MlirOp, Ctx.Context )
generateClosureFuncWithCaptures ctx funcName closureInfo body monoType =
    let
        fastCloneName =
            funcName ++ "$cap"

        captureTypes : List ( String, MlirType )
        captureTypes =
            List.indexedMap
                (\idx ( _, expr, _ ) ->
                    ( "%cap_" ++ String.fromInt idx, Types.monoTypeToAbi (Mono.typeOf expr) )
                )
                closureInfo.captures

        paramPairs : List ( String, MlirType )
        paramPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, Types.monoTypeToAbi ty ))
                closureInfo.params

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
    in
    ( [ fastCloneOp ], ctx1 )



-- ====== GENERATE TAIL FUNC ======


{-| Builds the function `funcName` of a tail-recursive definition, its body
compiled to a loop by `Compiler.Generate.MLIR.TailRec`.

The function returns what `monoType` gives after `params`, which is itself a
function type when the definition has fewer parameters than its type has
arrows. With `maybeSret`, the loop returns the fields of the tuple result
separately: the function is emitted as the worker `funcName$sret` with a shim
under `funcName` that builds the boxed tuple, as for a closure. Crashes when
that tuple does not have two or three fields.

-}
generateTailFunc : Ctx.Context -> String -> List ( Name.Name, Mono.MonoType ) -> Mono.MonoExpr -> Mono.MonoType -> Maybe Ctx.SretInfo -> ( List MlirOp, Ctx.Context )
generateTailFunc ctx funcName params expr monoType maybeSret =
    let
        funcArgPairs : List ( String, MlirType )
        funcArgPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, Types.monoTypeToAbi ty ))
                params

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

        actualReturnType =
            Ctx.residualResultType (List.length params) monoType

        retTy =
            Types.monoTypeToAbi actualReturnType

        ( bodyOps, ctx1 ) =
            TailRec.compileTailFuncToWhile ctxWithArgs funcName funcArgPairs (List.map Tuple.second params) expr retTy maybeSret

        ( bodyNonTermOps, bodyTerminator ) =
            case List.reverse bodyOps of
                term :: rest ->
                    ( List.reverse rest, term )

                [] ->
                    -- Not expected: TailRec always ends the body with a return.
                    let
                        ( dummyOps, dummyVar, ctxDummy ) =
                            Expr.createDummyValue ctx1 retTy

                        ( _, dummyRetOp ) =
                            Ops.ecoReturn ctxDummy dummyVar retTy
                    in
                    ( dummyOps, dummyRetOp )

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
                    Ops.ecoCallNamedMulti ctxS1 sResultPairs (funcName ++ "$sret") funcArgPairs

                ( sBoxVar, ctxS3 ) =
                    Ctx.freshVar ctxS2

                ( ctxS4, sConstructOp ) =
                    case sResultPairs of
                        [ a, b ] ->
                            Ops.ecoConstructTuple2 ctxS3 sBoxVar a b sretInfo.layout.unboxedBitmap

                        [ a, b, c ] ->
                            Ops.ecoConstructTuple3 ctxS3 sBoxVar a b c sretInfo.layout.unboxedBitmap

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


{-| Builds the constructor function `funcName` for the constructor laid out by
`ctorLayout`, and registers its type with the context.

A nullary constructor gives a function with no parameters returning a
constant: `Nothing`, `True` or `False` of elm/core give their `eco.constant`,
and any other gives a null-cons constant carrying its tag, which must fit
(`CtorTag.checkNullConsCapacity`). A constructor with fields takes one
parameter per field at the field's ABI type, boxes those the layout stores
boxed, and allocates the value with `eco.construct.custom`.

-}
generateCtor : Ctx.Context -> String -> Types.CtorLayout -> Mono.MonoType -> ( Ctx.Context, MlirOp )
generateCtor ctx funcName ctorLayout monoType =
    let
        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType monoType ctx

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

        -- The constructor's home is the home of the custom type it builds.
        wellKnownName : Maybe String
        wellKnownName =
            case ctorResultMonoType of
                Mono.MCustom _ home _ _ ->
                    if CtorTag.isEmbeddedConstantCtor home ctorLayout.name then
                        constructorName

                    else
                        Nothing

                _ ->
                    Nothing
    in
    if arity == 0 then
        let
            ( resultVar, ctx1 ) =
                Ctx.freshVar ctxWithType

            ( ctx2, valueOp ) =
                case wellKnownName of
                    Just "Nothing" ->
                        Ops.ecoConstantNothing ctx1 resultVar

                    Just "True" ->
                        Ops.ecoConstantTrue ctx1 resultVar

                    Just "False" ->
                        Ops.ecoConstantFalse ctx1 resultVar

                    _ ->
                        Ops.ecoConstantNullCons ctx1
                            resultVar
                            (CtorTag.checkNullConsCapacity
                                (Name.toElmString ctorLayout.name)
                                ctorLayout.tag
                            )

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
        let
            argNames : List String
            argNames =
                List.indexedMap
                    (\i _ -> "%arg" ++ String.fromInt i)
                    ctorLayout.fields

            -- A parameter's ABI type and its field's stored type can differ:
            -- a field the layout stores boxed may still arrive as a primitive.
            argTypes : List MlirType
            argTypes =
                List.map (\field -> Types.monoTypeToAbi field.monoType) ctorLayout.fields

            slotTypes : List MlirType
            slotTypes =
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

            ( boxOpsRev, slotPairsRev, ctxBoxed ) =
                List.foldl
                    (\( ( argName, argTy ), slotTy ) ( opsAcc, pairsAcc, ctxAcc ) ->
                        let
                            ( moreOps, slotVar, ctxNext ) =
                                Expr.coerceResultToType ctxAcc argName argTy slotTy
                        in
                        ( List.reverse moreOps ++ opsAcc, ( slotVar, slotTy ) :: pairsAcc, ctxNext )
                    )
                    ( [], [], ctxFreshScope )
                    (List.map2 Tuple.pair argPairs slotTypes)

            ( resultVar, ctx1 ) =
                Ctx.freshVar ctxBoxed

            ( ctx2, constructOp ) =
                Ops.ecoConstructCustom ctx1 resultVar ctorLayout.tag arity (Types.ctorSlotKinds ctorLayout) (List.reverse slotPairsRev) constructorName

            ( _, returnOp ) =
                Ops.ecoReturn ctx2 resultVar Types.ecoValue

            region : MlirRegion
            region =
                Ops.mkRegion argPairs (List.reverse boxOpsRev ++ [ constructOp ]) returnOp

            ( ctxOut, funcOp ) =
                Ops.funcFunc ctx2 funcName argPairs Types.ecoValue region
        in
        ( ctxOut, attachLogical funcOp )



-- ====== GENERATE ENUM ======


{-| Builds the function `funcName` of an enum constructor: no parameters,
returning a constant. `maybeCtor` is the constructor's home and name; `Nothing`,
`True` and `False` of elm/core give their `eco.constant`, and any other
constructor a null-cons constant carrying `tag`, which must fit
(`CtorTag.checkNullConsCapacity`). The type is registered with the context.
-}
generateEnum : Ctx.Context -> String -> Int -> Mono.MonoType -> Maybe ( ModuleName.Canonical, String ) -> ( Ctx.Context, MlirOp )
generateEnum ctx funcName tag monoType maybeCtor =
    let
        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType monoType ctx

        ( resultVar, ctx1 ) =
            Ctx.freshVar ctxWithType

        maybeCtorName : Maybe String
        maybeCtorName =
            Maybe.map Tuple.second maybeCtor

        wellKnownName : Maybe String
        wellKnownName =
            case maybeCtor of
                Just ( home, name ) ->
                    if CtorTag.isEmbeddedConstantCtor home name then
                        Just name

                    else
                        Nothing

                Nothing ->
                    Nothing

        ( ctx2, valueOp ) =
            case wellKnownName of
                Just "True" ->
                    Ops.ecoConstantTrue ctx1 resultVar

                Just "False" ->
                    Ops.ecoConstantFalse ctx1 resultVar

                Just "Nothing" ->
                    Ops.ecoConstantNothing ctx1 resultVar

                _ ->
                    -- tag is already the effective tag; it is used as given.
                    Ops.ecoConstantNullCons ctx1
                        resultVar
                        (CtorTag.checkNullConsCapacity
                            (Maybe.withDefault "<enum>" maybeCtorName)
                            tag
                        )

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


{-| Builds the private function `funcName` for an extern of type `monoType`.
Its body only returns a placeholder value of the result type, built by
`generateStubValue`.
-}
generateExtern : Ctx.Context -> String -> Mono.MonoType -> ( Ctx.Context, MlirOp )
generateExtern ctx funcName monoType =
    let
        ( argMonoTypes, resultMonoType ) =
            Mono.decomposeFunctionType monoType

        argMlirTypes : List MlirType
        argMlirTypes =
            List.map Types.monoTypeToAbi argMonoTypes

        resultMlirType : MlirType
        resultMlirType =
            Types.monoTypeToAbi resultMonoType

        argPairs : List ( String, MlirType )
        argPairs =
            List.indexedMap (\i ty -> ( "%arg" ++ String.fromInt i, ty )) argMlirTypes

        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | nextVar = List.length argPairs }

        ( stubVar, ctx1 ) =
            Ctx.freshVar ctxWithArgs

        ( ctx2, stubOp ) =
            generateStubValue ctx1 stubVar resultMlirType

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

        funcOpWithLogical =
            LogicalTypes.addLogicalTypesAttr
                ctxOut.ecoConfig.logicalTypes.customMaxFields
                ctxOut.typeRegistry.ctorShapes
                argMonoTypes
                resultMonoType
                funcOp
    in
    ( ctxOut, funcOpWithLogical )


{-| Builds the private function `funcName` of an effect manager leaf, the
`command` or `subscription` of the effect module `homeModuleName`. It returns
the result of `Elm_Kernel_Platform_leaf` given the module name as a string and
its first parameter, which wraps the effect value as a leaf of the manager's
effects. Only `%arg0` is passed, whatever the number of parameters `monoType`
gives.
-}
generateManagerLeaf : Ctx.Context -> String -> String -> Mono.MonoType -> ( Ctx.Context, MlirOp )
generateManagerLeaf ctx funcName homeModuleName monoType =
    let
        ( argMonoTypes, resultMonoType ) =
            Mono.decomposeFunctionType monoType

        argMlirTypes : List MlirType
        argMlirTypes =
            List.map Types.monoTypeToAbi argMonoTypes

        resultMlirType : MlirType
        resultMlirType =
            Types.monoTypeToAbi resultMonoType

        argPairs : List ( String, MlirType )
        argPairs =
            List.indexedMap (\i ty -> ( "%arg" ++ String.fromInt i, ty )) argMlirTypes

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

        ( homeVar, ctx1 ) =
            Ctx.freshVar ctxWithArgs

        ( ctx2, homeOp ) =
            Ops.ecoStringLiteral ctx1 homeVar homeModuleName

        ( resultVar, ctx3 ) =
            Ctx.freshVar ctx2

        ( ctx4, callOp ) =
            Ops.ecoCallNamed ctx3
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


{-| Builds a placeholder value of `mlirType` named `resultVar`: zero for
`i64`, `f64` and `i16`, `False` for `i1`, and `unit` for any other type.
-}
generateStubValue : Ctx.Context -> String -> MlirType -> ( Ctx.Context, MlirOp )
generateStubValue ctx resultVar mlirType =
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
            Ops.ecoConstantUnit ctx resultVar


{-| Builds the declaration of the kernel function `info` describes: a private
`func.func` at the recorded ABI types, marked `is_kernel`, whose body only
returns a placeholder value because `func.func` must have a body. Lowering
replaces it by an external declaration.

It is also marked `eco.gc_leaf` when the configuration enables kernel gc-leaf
marking and `info` records the kernel as a gc-leaf. Its logical types are
recorded as unknown, since a kernel declaration carries no Elm types.

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

        argPairs : List ( String, MlirType )
        argPairs =
            List.indexedMap (\i ty -> ( "%arg" ++ String.fromInt i, ty )) argMlirTypes

        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | nextVar = List.length argPairs }

        ( stubVar, ctx1 ) =
            Ctx.freshVar ctxWithArgs

        ( ctx2, stubOp ) =
            generateStubValueFromMlirType ctx1 stubVar resultMlirType

        ( ctx3, returnOp ) =
            Ops.ecoReturn ctx2 stubVar resultMlirType

        region : MlirRegion
        region =
            Ops.mkRegion argPairs [ stubOp ] returnOp

        baseAttrs =
            Dict.fromList
                [ ( "sym_name", StringAttr info.symbolName )
                , ( "sym_visibility", VisibilityAttr Private )
                , ( "is_kernel", BoolAttr True )
                , ( "function_type"
                  , TypeAttr
                        (FunctionType
                            { inputs = argMlirTypes
                            , results = [ resultMlirType ]
                            }
                        )
                  )
                ]

        -- A unit attribute: lowering tests only for its presence, so a false
        -- value would still read as set.
        attrs =
            if ctx.ecoConfig.kernelGcLeaf && info.gcLeaf then
                Dict.insert "eco.gc_leaf" UnitAttr baseAttrs

            else
                baseAttrs

        ( ctxOut, funcOp ) =
            Ops.mlirOp ctx3 "func.func"
                |> Ops.opBuilder.withRegions [ region ]
                |> Ops.opBuilder.withAttrs attrs
                |> Ops.opBuilder.build

        funcOpWithLogical =
            LogicalTypes.addLogicalTypesAttrUnknown
                argMlirTypes
                resultMlirType
                funcOp
    in
    ( ctxOut, funcOpWithLogical )


{-| Builds a placeholder value of `mlirType` named `resultVar` for a kernel
declaration's body: zero for `i64`, `f64` and `i16`, `False` for `i1`, and
`unit` for any other type.
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
            Ops.ecoConstantUnit ctx resultVar
