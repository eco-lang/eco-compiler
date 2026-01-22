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
import Compiler.Data.Name as Name
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Expr as Expr
import Compiler.Generate.MLIR.Names as Names
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Dict
import Mlir.Loc
import Mlir.Mlir as Mlir exposing (MlirAttr(..), MlirOp, MlirRegion(..), MlirType(..), Visibility(..))
import OrderedDict



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

        region : MlirRegion
        region =
            if exprResult.isTerminated then
                -- Expression is a control-flow exit (eco.case, eco.jump).
                -- The ops already contain the terminator - don't add eco.return.
                -- IMPORTANT: Do NOT access exprResult.resultVar here - it is meaningless!
                Ops.mkRegionTerminatedByOps argPairs exprResult.ops

            else
                -- Normal expression - add eco.return with the result value.
                let
                    -- Handle type mismatch between expression result and expected return type.
                    -- Uses symmetric coercion: primitive <-> !eco.value in either direction.
                    ( coerceOps, finalVar, ctxFinal ) =
                        Expr.coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType returnType

                    ( _, returnOp ) =
                        Ops.ecoReturn ctxFinal finalVar returnType
                in
                Ops.mkRegion argPairs (exprResult.ops ++ coerceOps) returnOp

        ( ctx2, funcOp ) =
            Ops.funcFunc exprResult.ctx funcName argPairs returnType region
    in
    ( funcOp, ctx2 )



-- ====== GENERATE TAIL FUNC ======


generateTailFunc : Ctx.Context -> String -> List ( Name.Name, Mono.MonoType ) -> Mono.MonoExpr -> Mono.MonoType -> ( MlirOp, Ctx.Context )
generateTailFunc ctx funcName params expr monoType =
    let
        -- Function parameters use anonymous names (%arg0, %arg1, ...) to avoid
        -- collision with joinpoint parameters that the body actually references.
        funcArgPairs : List ( String, MlirType )
        funcArgPairs =
            List.indexedMap
                (\i ( _, ty ) -> ( "%arg" ++ String.fromInt i, Types.monoTypeToMlir ty ))
                params

        -- Joinpoint parameters use the original names (%n, %acc, ...) that
        -- the body expression expects.
        jpArgPairs : List ( String, MlirType )
        jpArgPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, Types.monoTypeToMlir ty ))
                params

        -- Create fresh varMappings with only joinpoint parameters
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

        retTy =
            Types.monoTypeToMlir monoType

        -- Generate multi-block joinpoint body for tail-recursive if-then-else
        ( jpBodyRegion, ctx1 ) =
            generateTailRecursiveBody ctxWithArgs expr retTy

        -- Continuation region: required by joinpoint semantics but never reached
        -- for pure tail-recursive functions. Create a dummy return.
        ( dummyOps, dummyVar, ctx2 ) =
            Expr.createDummyValue ctx1 retTy

        ( ctx3, dummyRetOp ) =
            Ops.ecoReturn ctx2 dummyVar retTy

        contRegion : MlirRegion
        contRegion =
            Ops.mkRegion [] dummyOps dummyRetOp

        -- Create the joinpoint (ID 0) with named params that body expects
        ( ctx4, jpOp ) =
            Ops.ecoJoinpoint ctx3 0 jpArgPairs jpBodyRegion contRegion [ retTy ]

        -- Initial jump to enter the joinpoint, passing function args
        argTypes : List MlirType
        argTypes =
            List.map Tuple.second funcArgPairs

        initialJumpAttrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr argTypes) )
                , ( "target", IntAttr Nothing 0 )
                ]

        ( ctx5, initialJumpOp ) =
            Ops.mlirOp ctx4 "eco.jump"
                |> Ops.opBuilder.withOperands (List.map Tuple.first funcArgPairs)
                |> Ops.opBuilder.withAttrs initialJumpAttrs
                |> Ops.opBuilder.isTerminator True
                |> Ops.opBuilder.build

        -- Function body: joinpoint definition + initial jump
        funcBodyRegion : MlirRegion
        funcBodyRegion =
            Ops.mkRegion funcArgPairs [ jpOp ] initialJumpOp

        ( ctx6, funcOp ) =
            Ops.funcFunc ctx5 funcName funcArgPairs retTy funcBodyRegion
    in
    ( funcOp, ctx6 )


{-| Generate a multi-block region for a tail-recursive function body.
For an if-then-else where one branch returns and one branch tail-calls,
we generate:
  - Entry block: evaluate condition, cf.cond_br to ^return or ^recurse
  - ^return block: evaluate return expression, eco.return
  - ^recurse block: evaluate tail call args, eco.jump 0(...)
-}
generateTailRecursiveBody : Ctx.Context -> Mono.MonoExpr -> MlirType -> ( MlirRegion, Ctx.Context )
generateTailRecursiveBody ctx expr retTy =
    case expr of
        Mono.MonoIf [ ( condExpr, thenExpr ) ] elseExpr _ ->
            -- Single branch if-then-else
            case ( isTailCall thenExpr, isTailCall elseExpr ) of
                ( False, True ) ->
                    -- then = return, else = tail call
                    -- Condition true -> return, false -> recurse
                    generateTailRecBody ctx condExpr thenExpr elseExpr retTy True

                ( True, False ) ->
                    -- then = tail call, else = return
                    -- Condition true -> recurse, false -> return
                    generateTailRecBody ctx condExpr elseExpr thenExpr retTy False

                _ ->
                    -- Both or neither are tail calls - fall back to simple generation
                    generateSimpleBody ctx expr retTy

        _ ->
            -- Not a simple if-then-else, fall back
            generateSimpleBody ctx expr retTy


{-| Check if an expression is a tail call.
-}
isTailCall : Mono.MonoExpr -> Bool
isTailCall expr =
    case expr of
        Mono.MonoTailCall _ _ _ ->
            True

        _ ->
            False


{-| Generate the multi-block region for tail recursion.
condTrueReturns: True if condition=true should return, False if condition=true should recurse
-}
generateTailRecBody : Ctx.Context -> Mono.MonoExpr -> Mono.MonoExpr -> Mono.MonoExpr -> MlirType -> Bool -> ( MlirRegion, Ctx.Context )
generateTailRecBody ctx condExpr returnExpr tailCallExpr retTy condTrueReturns =
    let
        -- Generate condition evaluation
        condResult =
            Expr.generateExpr ctx condExpr

        condVar =
            condResult.resultVar

        -- Generate return branch
        returnResult =
            Expr.generateExpr condResult.ctx returnExpr

        ( returnCoerceOps, returnFinalVar, returnCtx ) =
            Expr.coerceResultToType returnResult.ctx returnResult.resultVar returnResult.resultType retTy

        ( returnCtx2, returnOp ) =
            Ops.ecoReturn returnCtx returnFinalVar retTy

        returnBlockOps =
            returnResult.ops ++ returnCoerceOps

        -- Generate tail call branch
        tailCallResult =
            generateTailCallOps returnCtx2 tailCallExpr

        -- Build the multi-block region
        -- Entry block: condition ops + cf.cond_br
        -- ^ret block: return ops + eco.return
        -- ^rec block: tail call ops + eco.jump
        ( returnBlockName, recurseBlockName ) =
            if condTrueReturns then
                ( "ret", "rec" )

            else
                ( "rec", "ret" )

        -- cf.cond_br branches to trueBlock when condition is true
        ( branchCtx, branchOp ) =
            if condTrueReturns then
                -- true -> return, false -> recurse
                Ops.cfCondBr tailCallResult.ctx condVar "ret" "rec"

            else
                -- true -> recurse, false -> return
                Ops.cfCondBr tailCallResult.ctx condVar "rec" "ret"

        -- Build regions using OrderedDict for additional blocks
        entryBlock : Mlir.MlirBlock
        entryBlock =
            { args = [], body = condResult.ops, terminator = branchOp }

        returnBlock : Mlir.MlirBlock
        returnBlock =
            { args = [], body = returnBlockOps, terminator = returnOp }

        recurseBlock : Mlir.MlirBlock
        recurseBlock =
            { args = [], body = tailCallResult.ops, terminator = tailCallResult.terminator }

        region : MlirRegion
        region =
            MlirRegion
                { entry = entryBlock
                , blocks =
                    OrderedDict.empty
                        |> OrderedDict.insert "ret" returnBlock
                        |> OrderedDict.insert "rec" recurseBlock
                }
    in
    ( region, branchCtx )


{-| Generate ops for a tail call expression, returning the ops and the eco.jump terminator.
-}
generateTailCallOps : Ctx.Context -> Mono.MonoExpr -> { ops : List MlirOp, terminator : MlirOp, ctx : Ctx.Context }
generateTailCallOps ctx expr =
    case expr of
        Mono.MonoTailCall _ args _ ->
            let
                -- Generate arguments
                ( argsOps, argsWithTypes, ctx1 ) =
                    List.foldl
                        (\( _, argExpr ) ( accOps, accVars, accCtx ) ->
                            let
                                result =
                                    Expr.generateExpr accCtx argExpr
                            in
                            ( accOps ++ result.ops
                            , accVars ++ [ ( result.resultVar, result.resultType ) ]
                            , result.ctx
                            )
                        )
                        ( [], [], ctx )
                        args

                argVarNames =
                    List.map Tuple.first argsWithTypes

                argVarTypes =
                    List.map Tuple.second argsWithTypes

                jumpAttrs =
                    Dict.fromList
                        [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr argVarTypes) )
                        , ( "target", IntAttr Nothing 0 )
                        ]

                ( ctx2, jumpOp ) =
                    Ops.mlirOp ctx1 "eco.jump"
                        |> Ops.opBuilder.withOperands argVarNames
                        |> Ops.opBuilder.withAttrs jumpAttrs
                        |> Ops.opBuilder.isTerminator True
                        |> Ops.opBuilder.build
            in
            { ops = argsOps, terminator = jumpOp, ctx = ctx2 }

        _ ->
            -- Should not happen - we checked isTailCall
            { ops = []
            , terminator =
                { name = "error"
                , id = "error"
                , operands = []
                , results = []
                , attrs = Dict.empty
                , regions = []
                , isTerminator = False
                , loc = Mlir.Loc.unknown
                , successors = []
                }
            , ctx = ctx
            }


{-| Simple body generation for non-standard patterns - falls back to single block with eco.return.
-}
generateSimpleBody : Ctx.Context -> Mono.MonoExpr -> MlirType -> ( MlirRegion, Ctx.Context )
generateSimpleBody ctx expr retTy =
    let
        exprResult =
            Expr.generateExpr ctx expr

        ( coerceOps, finalVar, coerceCtx ) =
            Expr.coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType retTy

        ( returnCtx, returnOp ) =
            Ops.ecoReturn coerceCtx finalVar retTy

        region =
            Ops.mkRegion [] (exprResult.ops ++ coerceOps) returnOp
    in
    ( region, returnCtx )



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
