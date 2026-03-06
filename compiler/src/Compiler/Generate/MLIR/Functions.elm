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
import Compiler.Generate.MLIR.Names as Names
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.TailRec as TailRec
import Compiler.Generate.MLIR.Types as Types
import Compiler.Monomorphize.Registry as Registry
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirRegion, MlirType(..), Visibility(..))



-- ====== GENERATE MAIN ENTRY ======


{-| Generate the main entry point function.
-}
generateMainEntry : Ctx.Context -> Mono.MainInfo -> List MlirOp
generateMainEntry ctx mainInfo =
    case mainInfo of
        Mono.StaticMain mainSpecId ->
            let
                ( callVar, ctx1 ) =
                    Ctx.freshVar ctx

                mainFuncName : String
                mainFuncName =
                    specIdToFuncName ctx.registry mainSpecId

                ( ctx2, callOp ) =
                    Ops.ecoCallNamed ctx1 callVar mainFuncName [] Types.ecoValue

                ( ctx3, returnOp ) =
                    Ops.ecoReturn ctx2 callVar Types.ecoValue

                region : MlirRegion
                region =
                    Ops.mkRegion [] [ callOp ] returnOp

                ( _, mainOp ) =
                    Ops.funcFunc ctx3 "main" [] Types.ecoValue region
            in
            [ mainOp ]



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
    in
    case node of
        Mono.MonoDefine expr monoType ->
            generateDefine ctx funcName expr monoType

        Mono.MonoTailFunc params expr monoType ->
            let
                ( op, ctx1 ) =
                    generateTailFunc ctx funcName params expr monoType
            in
            ( [ op ], ctx1 )

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
                        Just ( Mono.Global _ ctorName, _, _ ) ->
                            Just (Name.toElmString ctorName)

                        Just ( Mono.Accessor _, _, _ ) ->
                            -- Accessors don't have constructor names
                            Nothing

                        Nothing ->
                            Nothing

                ( ctx1, op ) =
                    generateEnum ctx funcName tag monoType maybeCtorName
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
                    generateManagerLeaf ctx funcName homeModuleName monoType
            in
            ( [ op ], ctx1 )

        Mono.MonoPortIncoming expr monoType ->
            generateDefine ctx funcName expr monoType

        Mono.MonoPortOutgoing expr monoType ->
            generateDefine ctx funcName expr monoType

        Mono.MonoCycle definitions monoType ->
            let
                ( op, ctx1 ) =
                    generateCycle ctx funcName definitions monoType
            in
            ( [ op ], ctx1 )


specIdToFuncName : Mono.SpecializationRegistry -> Mono.SpecId -> String
specIdToFuncName registry specId =
    case Registry.lookupSpecKey specId registry of
        Just ( Mono.Global home name, _, _ ) ->
            Names.canonicalToMLIRName home ++ "_" ++ Names.sanitizeName name ++ "_$_" ++ String.fromInt specId

        Just ( Mono.Accessor fieldName, _, _ ) ->
            "accessor_" ++ Names.sanitizeName fieldName ++ "_$_" ++ String.fromInt specId

        Nothing ->
            "unknown_$_" ++ String.fromInt specId



-- ====== GENERATE DEFINE ======


generateDefine : Ctx.Context -> String -> Mono.MonoExpr -> Mono.MonoType -> ( List MlirOp, Ctx.Context )
generateDefine ctx funcName expr monoType =
    case expr of
        Mono.MonoClosure closureInfo body _ ->
            generateClosureFunc ctx funcName closureInfo body monoType

        _ ->
            -- Value (thunk) - wrap in nullary function
            let
                -- Thunks have no parameters, but still need fresh scope.
                ctxFreshScope : Ctx.Context
                ctxFreshScope =
                    { ctx | nextVar = 0, varMappings = Dict.empty }

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
            ( [ funcOp ], ctx2 )


{-| Generate closure functions.
For closures with captures: generates both fast clone (captures + params)
and generic clone (Closure\* + params).
For zero-capture closures: generates just the original function.
-}
generateClosureFunc : Ctx.Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ( List MlirOp, Ctx.Context )
generateClosureFunc ctx funcName closureInfo body monoType =
    let
        hasCaptures =
            not (List.isEmpty closureInfo.captures)
    in
    if hasCaptures then
        -- Two-clone model: fast clone + generic clone
        generateClosureFuncWithClones ctx funcName closureInfo body monoType

    else
        -- Zero captures: single function (original lambda)
        generateClosureFuncSingle ctx funcName closureInfo body monoType


{-| Generate a single function for zero-capture closures.
-}
generateClosureFuncSingle : Ctx.Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ( List MlirOp, Ctx.Context )
generateClosureFuncSingle ctx funcName closureInfo body monoType =
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

        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | nextVar = List.length closureInfo.params, varMappings = freshVarMappings }

        exprResult : Expr.ExprResult
        exprResult =
            Expr.generateExpr ctxWithArgs body

        extractedReturnType : Mono.MonoType
        extractedReturnType =
            case monoType of
                Mono.MFunction _ retType ->
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
    in
    ( [ funcOp ], ctx2 )


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
                Mono.MFunction _ retType ->
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

        ctxFastClone : Ctx.Context
        ctxFastClone =
            { ctx
                | nextVar = List.length fastCloneArgs
                , varMappings = fastCloneMappings
            }

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

        ( ctx1, fastCloneOp ) =
            Ops.funcFunc exprResult.ctx fastCloneName fastCloneArgs returnType fastCloneRegion

        -- Generic clone: (Closure*, params...) -> R
        -- Body: load captures, call fast clone
        captureSpecs : List ( MlirType, Bool )
        captureSpecs =
            List.map
                (\( _, expr, isUnboxed ) ->
                    ( Types.monoTypeToAbi (Mono.typeOf expr), isUnboxed )
                )
                closureInfo.captures

        ( genericCloneOp, ctx2 ) =
            generateGenericCloneFunc ctx1 genericCloneName fastCloneName captureSpecs paramPairs returnType
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

        -- Reset nextVar for the generic clone's own SSA scope.
        -- Entry block args are %0 (%closure), %1..%N (params), so
        -- body SSA values start after those.
        ctxFreshScope =
            { ctx | nextVar = List.length genericCloneArgs }

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
                    ( accOps ++ [ projectOp ], accVars ++ [ ( captureVar, captureType ) ], ctxB )
                )
                ( [], [], ctx )
                (List.indexedMap Tuple.pair captureSpecs)

        -- Build the call to the fast clone with captures + params
        callArgs =
            captureVarsWithTypes ++ paramPairs

        ( resultVar, ctxAfterFresh ) =
            Ctx.freshVar ctxAfterProject

        ( ctxFinal, callOp ) =
            Ops.ecoCallNamed ctxAfterFresh resultVar fastCloneName callArgs returnType
    in
    ( projectOps ++ [ callOp ], resultVar, ctxFinal )



-- ====== GENERATE TAIL FUNC ======


generateTailFunc : Ctx.Context -> String -> List ( Name.Name, Mono.MonoType ) -> Mono.MonoExpr -> Mono.MonoType -> ( MlirOp, Ctx.Context )
generateTailFunc ctx funcName params expr monoType =
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

        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | nextVar = List.length params, varMappings = freshVarMappings }

        -- monoType is the full curried function type (e.g., MFunction [MInt] (MFunction [MInt] MInt))
        -- Use decomposeFunctionType to extract the FINAL return type after all args are consumed.
        -- For sumHelper : Int -> Int -> Int, this extracts MInt (not MFunction [MInt] MInt).
        ( _, actualReturnType ) =
            Mono.decomposeFunctionType monoType

        retTy =
            Types.monoTypeToAbi actualReturnType

        -- Use TailRec to compile the function body to scf.while
        ( bodyOps, ctx1 ) =
            TailRec.compileTailFuncToWhile ctxWithArgs funcName funcArgPairs expr retTy

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
    in
    ( funcOp, ctx2 )



-- ====== GENERATE CTOR ======


generateCtor : Ctx.Context -> String -> Types.CtorLayout -> Mono.MonoType -> ( Ctx.Context, MlirOp )
generateCtor ctx funcName ctorLayout monoType =
    -- Register the custom type and its constructor for the type graph
    let
        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType monoType ctx

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
                        -- Not a well-known constant, use eco.construct.custom
                        Ops.ecoConstructCustom ctx1 resultVar ctorLayout.tag 0 0 [] constructorName

            ( ctx3, returnOp ) =
                Ops.ecoReturn ctx2 resultVar Types.ecoValue

            region : MlirRegion
            region =
                Ops.mkRegion [] [ valueOp ] returnOp
        in
        Ops.funcFunc ctx3 funcName [] Types.ecoValue region

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

            ( resultVar, ctx1 ) =
                Ctx.freshVar { ctxWithType | nextVar = arity }

            ( ctx2, constructOp ) =
                Ops.ecoConstructCustom ctx1 resultVar ctorLayout.tag arity ctorLayout.unboxedBitmap argPairs constructorName

            ( ctx3, returnOp ) =
                Ops.ecoReturn ctx2 resultVar Types.ecoValue

            region : MlirRegion
            region =
                Ops.mkRegion argPairs [ constructOp ] returnOp
        in
        Ops.funcFunc ctx3 funcName argPairs Types.ecoValue region



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
                    -- Not a well-known constant, use eco.construct.custom
                    Ops.ecoConstructCustom ctx1 resultVar tag 0 0 [] maybeCtorName

        ( ctx3, returnOp ) =
            Ops.ecoReturn ctx2 resultVar Types.ecoValue

        region : MlirRegion
        region =
            Ops.mkRegion [] [ valueOp ] returnOp
    in
    Ops.funcFunc ctx3 funcName [] Types.ecoValue region



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
    in
    Ops.mlirOp ctx3 "func.func"
        |> Ops.opBuilder.withRegions [ region ]
        |> Ops.opBuilder.withAttrs attrs
        |> Ops.opBuilder.build


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

        -- Start fresh var counter after block args
        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | nextVar = List.length argPairs }

        -- Create string constant for home module name
        ( homeVar, ctx1 ) =
            Ctx.freshVar ctxWithArgs

        ( ctx2, homeOp ) =
            Ops.ecoStringLiteral ctx1 homeVar homeModuleName

        -- Call Elm_Kernel_Platform_leaf(home, arg0)
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
    in
    Ops.mlirOp ctx5 "func.func"
        |> Ops.opBuilder.withRegions [ region ]
        |> Ops.opBuilder.withAttrs attrs
        |> Ops.opBuilder.build


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
generateKernelDecl : Ctx.Context -> String -> ( List MlirType, MlirType ) -> ( Ctx.Context, MlirOp )
generateKernelDecl ctx funcName ( argMlirTypes, resultMlirType ) =
    let
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
                [ ( "sym_name", StringAttr funcName )
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
    in
    Ops.mlirOp ctx3 "func.func"
        |> Ops.opBuilder.withRegions [ region ]
        |> Ops.opBuilder.withAttrs attrs
        |> Ops.opBuilder.build


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



-- ====== GENERATE CYCLE ======


generateCycle : Ctx.Context -> String -> List ( Name.Name, Mono.MonoExpr ) -> Mono.MonoType -> ( MlirOp, Ctx.Context )
generateCycle ctx funcName definitions monoType =
    -- Generate mutually recursive definitions
    -- For now, generate a thunk that creates a record of all the cycle definitions
    let
        -- Generate expressions and collect results with their ACTUAL SSA types
        ( defOps, defVarsWithTypes, finalCtx ) =
            List.foldl
                (\( _, expr ) ( accOps, accVars, accCtx ) ->
                    let
                        result : Expr.ExprResult
                        result =
                            Expr.generateExpr accCtx expr
                    in
                    ( accOps ++ result.ops
                    , accVars ++ [ ( result.resultVar, result.resultType ) ]
                    , result.ctx
                    )
                )
                ( [], [], ctx )
                definitions

        -- Box any primitive values before storing in the cycle using actual SSA types
        ( boxOps, boxedVars, ctxAfterBox ) =
            Expr.boxArgsWithMlirTypes finalCtx defVarsWithTypes

        ( resultVar, ctx1 ) =
            Ctx.freshVar ctxAfterBox

        arity : Int
        arity =
            List.length definitions

        defVarPairs : List ( String, MlirType )
        defVarPairs =
            List.map (\v -> ( v, Types.ecoValue )) boxedVars

        ( ctx2, cycleOp ) =
            Ops.ecoConstructRecord ctx1 resultVar defVarPairs arity 0

        ( ctx3, returnOp ) =
            Ops.ecoReturn ctx2 resultVar Types.ecoValue

        region : MlirRegion
        region =
            Ops.mkRegion [] (defOps ++ boxOps ++ [ cycleOp ]) returnOp

        ( ctx4, funcOp ) =
            Ops.funcFunc ctx3 funcName [] (Types.monoTypeToAbi monoType) region
    in
    ( funcOp, ctx4 )
