module Compiler.Generate.MLIR.Functions exposing (generateMainEntry, generateNode, generateKernelDecl)

{-| Function generation for the MLIR backend.

This module handles generation of all function types:

  - Main entry point
  - Defines (regular functions)
  - Tail functions
  - Constructors
  - Enums
  - Externs
  - Cycles

@docs generateMainEntry, generateNode, generateKernelDecl

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.Package as Pkg
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Expr as Expr
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
import Compiler.Generate.MLIR.Names as Names
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Data.Map as EveryDict
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirRegion(..), MlirType(..), Visibility(..))
import System.TypeCheck.IO as IO



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
-}
generateNode : Ctx.Context -> Mono.SpecId -> Mono.MonoNode -> ( MlirOp, Ctx.Context )
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
            generateTailFunc ctx funcName params expr monoType

        Mono.MonoCtor ctorLayout monoType ->
            let
                ( ctx1, op ) =
                    generateCtor ctx funcName ctorLayout monoType
            in
            ( op, ctx1 )

        Mono.MonoEnum tag monoType ->
            let
                -- Look up the spec key to get the constructor name
                maybeCtorName : Maybe String
                maybeCtorName =
                    case Mono.lookupSpecKey specId ctx.registry of
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
            ( op, ctx1 )

        Mono.MonoExtern monoType ->
            let
                ( ctx1, op ) =
                    generateExtern ctx funcName monoType
            in
            ( op, ctx1 )

        Mono.MonoPortIncoming expr monoType ->
            generateDefine ctx funcName expr monoType

        Mono.MonoPortOutgoing expr monoType ->
            generateDefine ctx funcName expr monoType

        Mono.MonoCycle definitions monoType ->
            generateCycle ctx funcName definitions monoType


specIdToFuncName : Mono.SpecializationRegistry -> Mono.SpecId -> String
specIdToFuncName registry specId =
    case Mono.lookupSpecKey specId registry of
        Just ( Mono.Global home name, _, _ ) ->
            Names.canonicalToMLIRName home ++ "_" ++ Names.sanitizeName name ++ "_$_" ++ String.fromInt specId

        Just ( Mono.Accessor fieldName, _, _ ) ->
            "accessor_" ++ Names.sanitizeName fieldName ++ "_$_" ++ String.fromInt specId

        Nothing ->
            "unknown_$_" ++ String.fromInt specId



-- ====== GENERATE DEFINE ======


{-| Debug helper: dump the structure of a MonoExpr showing all let bindings and var references.
-}
dumpMonoExprStructure : String -> Mono.MonoExpr -> String
dumpMonoExprStructure indent expr =
    case expr of
        Mono.MonoLet def body _ ->
            let
                ( defName, defExpr ) =
                    case def of
                        Mono.MonoDef name defBody ->
                            ( "MonoDef " ++ name, defBody )

                        Mono.MonoTailDef name _ defBody ->
                            ( "MonoTailDef " ++ name, defBody )
            in
            indent
                ++ "MonoLet ("
                ++ defName
                ++ ")\n"
                ++ indent
                ++ "  def =\n"
                ++ dumpMonoExprStructure (indent ++ "    ") defExpr
                ++ "\n"
                ++ indent
                ++ "  body =\n"
                ++ dumpMonoExprStructure (indent ++ "    ") body

        Mono.MonoClosure closureInfo innerBody _ ->
            let
                paramNames =
                    List.map Tuple.first closureInfo.params

                captureNames =
                    List.map (\( n, _, _ ) -> n) closureInfo.captures
            in
            indent
                ++ "MonoClosure (params=["
                ++ String.join ", " paramNames
                ++ "], captures=["
                ++ String.join ", " captureNames
                ++ "])\n"
                ++ dumpMonoExprStructure (indent ++ "  ") innerBody

        Mono.MonoVarLocal name _ ->
            indent ++ "MonoVarLocal " ++ name

        Mono.MonoVarGlobal _ specId _ ->
            indent ++ "MonoVarGlobal (specId=" ++ String.fromInt specId ++ ")"

        Mono.MonoCall _ func _ _ ->
            indent ++ "MonoCall\n" ++ dumpMonoExprStructure (indent ++ "  ") func

        Mono.MonoIf branches final _ ->
            indent ++ "MonoIf (" ++ String.fromInt (List.length branches) ++ " branches)"

        Mono.MonoCase _ _ _ _ _ ->
            indent ++ "MonoCase"

        _ ->
            indent ++ "Other"


generateDefine : Ctx.Context -> String -> Mono.MonoExpr -> Mono.MonoType -> ( MlirOp, Ctx.Context )
generateDefine ctx funcName expr monoType =
    case expr of
        Mono.MonoClosure closureInfo body _ ->
            generateClosureFunc ctx funcName closureInfo body monoType

        _ ->
            -- Value (thunk) - wrap in nullary function
            let
                -- Thunks have no parameters, but still need fresh scope
                ctxFreshScope : Ctx.Context
                ctxFreshScope =
                    { ctx | nextVar = 0, varMappings = Dict.empty }

                exprResult : Expr.ExprResult
                exprResult =
                    Expr.generateExpr ctxFreshScope expr

                retTy =
                    Types.monoTypeToMlir monoType

                -- Handle type mismatch between expression result and expected return type.
                -- Uses symmetric coercion: primitive <-> !eco.value in either direction.
                ( coerceOps, finalVar, ctxFinal ) =
                    Expr.coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType retTy

                ( ctx1, returnOp ) =
                    Ops.ecoReturn ctxFinal finalVar retTy

                region : MlirRegion
                region =
                    Ops.mkRegion [] (exprResult.ops ++ coerceOps) returnOp

                ( ctx2, funcOp ) =
                    Ops.funcFunc ctx1 funcName [] retTy region
            in
            ( funcOp, ctx2 )


generateClosureFunc : Ctx.Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ( MlirOp, Ctx.Context )
generateClosureFunc ctx funcName closureInfo body monoType =
    let
        argPairs : List ( String, MlirType )
        argPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, Types.monoTypeToMlir ty ))
                closureInfo.params

        -- Create fresh varMappings with only function parameters
        freshVarMappings : Dict.Dict String ( String, MlirType )
        freshVarMappings =
            List.foldl
                (\( name, ty ) acc ->
                    Dict.insert name ( "%" ++ name, Types.monoTypeToMlir ty ) acc
                )
                Dict.empty
                closureInfo.params

        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | nextVar = List.length closureInfo.params, varMappings = freshVarMappings }

        exprResult : Expr.ExprResult
        exprResult =
            Expr.generateExpr ctxWithArgs body

        -- Extract return type from the closure's full type, not the body's type.
        -- The body's type may be !eco.value if it's a parameter reference,
        -- but the caller expects the actual return type (e.g., i64 for identity 42).
        ( _, extractedReturnType ) =
            Types.decomposeFunctionType monoType

        returnType : MlirType
        returnType =
            Types.monoTypeToMlir extractedReturnType

        -- Handle type mismatch between expression result and expected return type.
        -- Uses symmetric coercion: primitive <-> !eco.value in either direction.
        ( coerceOps, finalVar, ctxFinal ) =
            Expr.coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType returnType

        ( ctx1, returnOp ) =
            Ops.ecoReturn ctxFinal finalVar returnType

        region : MlirRegion
        region =
            Ops.mkRegion argPairs (exprResult.ops ++ coerceOps) returnOp

        ( ctx2, funcOp ) =
            Ops.funcFunc ctx1 funcName argPairs returnType region
    in
    ( funcOp, ctx2 )



-- ====== GENERATE TAIL FUNC ======


generateTailFunc : Ctx.Context -> String -> List ( Name.Name, Mono.MonoType ) -> Mono.MonoExpr -> Mono.MonoType -> ( MlirOp, Ctx.Context )
generateTailFunc ctx funcName params expr monoType =
    let
        argPairs : List ( String, MlirType )
        argPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, Types.monoTypeToMlir ty ))
                params

        -- Create fresh varMappings with only function parameters
        freshVarMappings : Dict.Dict String ( String, MlirType )
        freshVarMappings =
            List.foldl
                (\( name, ty ) acc ->
                    Dict.insert name ( "%" ++ name, Types.monoTypeToMlir ty ) acc
                )
                Dict.empty
                params

        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            { ctx | nextVar = List.length params, varMappings = freshVarMappings }

        exprResult : Expr.ExprResult
        exprResult =
            Expr.generateExpr ctxWithArgs expr

        retTy =
            Types.monoTypeToMlir monoType

        -- Handle type mismatch between expression result and expected return type.
        -- Uses symmetric coercion: primitive <-> !eco.value in either direction.
        ( coerceOps, finalVar, ctxFinal ) =
            Expr.coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType retTy

        ( ctx1, returnOp ) =
            Ops.ecoReturn ctxFinal finalVar retTy

        region : MlirRegion
        region =
            Ops.mkRegion argPairs (exprResult.ops ++ coerceOps) returnOp

        ( ctx2, funcOp ) =
            Ops.funcFunc ctx1 funcName argPairs retTy region
    in
    ( funcOp, ctx2 )



-- ====== GENERATE CTOR ======


generateCtor : Ctx.Context -> String -> Mono.CtorLayout -> Mono.MonoType -> ( Ctx.Context, MlirOp )
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
                            Types.monoTypeToMlir field.monoType

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
            Types.decomposeFunctionType monoType

        -- Convert to MLIR types
        argMlirTypes : List MlirType
        argMlirTypes =
            List.map Types.monoTypeToMlir argMonoTypes

        resultMlirType : MlirType
        resultMlirType =
            Types.monoTypeToMlir resultMonoType

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


{-| Create a dummy value of the given MLIR type.
Used for case expressions where we need a placeholder result with the correct type
for the return after the eco.case (which will be replaced by the lowering pass).
-}
createDummyValue : Ctx.Context -> MlirType -> ( List MlirOp, String, Ctx.Context )
createDummyValue ctx mlirType =
    let
        ( resultVar, ctx1 ) =
            Ctx.freshVar ctx
    in
    case mlirType of
        I64 ->
            let
                ( ctx2, op ) =
                    Ops.arithConstantInt ctx1 resultVar 0
            in
            ( [ op ], resultVar, ctx2 )

        F64 ->
            let
                ( ctx2, op ) =
                    Ops.arithConstantFloat ctx1 resultVar 0.0
            in
            ( [ op ], resultVar, ctx2 )

        I1 ->
            let
                ( ctx2, op ) =
                    Ops.arithConstantBool ctx1 resultVar False
            in
            ( [ op ], resultVar, ctx2 )

        I16 ->
            let
                ( ctx2, op ) =
                    Ops.arithConstantChar ctx1 resultVar 0
            in
            ( [ op ], resultVar, ctx2 )

        _ ->
            -- For Types.ecoValue and other types, return Unit
            let
                ( ctx2, op ) =
                    Ops.ecoConstantUnit ctx1 resultVar
            in
            ( [ op ], resultVar, ctx2 )



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
            Ops.funcFunc ctx3 funcName [] (Types.monoTypeToMlir monoType) region
    in
    ( funcOp, ctx4 )
