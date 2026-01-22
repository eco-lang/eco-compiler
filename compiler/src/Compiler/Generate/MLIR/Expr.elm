module Compiler.Generate.MLIR.Expr exposing
    ( ExprResult
    , generateExpr
    , boxToEcoValue, coerceResultToType, boxArgsWithMlirTypes
    , createDummyValue
    )

{-| Expression generation for the MLIR backend.

This module handles generation of MLIR code for all Elm expressions.


# Result Type

@docs ExprResult


# Expression Generation

@docs generateExpr


# Data Structure Generation


# Boxing and Coercion

@docs boxToEcoValue, coerceResultToType, boxArgsWithMlirTypes

-}

import Bitwise
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Hex
import Compiler.Elm.Package as Pkg
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
import Compiler.Generate.MLIR.Names as Names
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Patterns as Patterns
import Compiler.Generate.MLIR.Types as Types
import Compiler.Optimize.Typed.DecisionTree as DT
import Dict
import Mlir.Loc as Loc
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Set
import System.TypeCheck.IO as IO
import Utils.Crash exposing (crash)



-- ====== EXPRESSION RESULT ======


{-| Result of generating MLIR code for an expression.
-}
type alias ExprResult =
    { ops : List MlirOp
    , resultVar : String
    , resultType : MlirType
    , ctx : Ctx.Context
    , isTerminated : Bool -- True if ops end with a terminator (eco.case, eco.jump)
    }


{-| Create an empty expression result with no ops.
-}
emptyResult : Ctx.Context -> String -> MlirType -> ExprResult
emptyResult ctx var ty =
    { ops = [], resultVar = var, resultType = ty, ctx = ctx, isTerminated = False }



-- ====== HELPER FUNCTIONS ======


specIdToFuncName : Mono.SpecializationRegistry -> Mono.SpecId -> String
specIdToFuncName registry specId =
    case Mono.lookupSpecKey specId registry of
        Just ( Mono.Global home name, _, _ ) ->
            Names.canonicalToMLIRName home ++ "_" ++ Names.sanitizeName name ++ "_$_" ++ String.fromInt specId

        Just ( Mono.Accessor fieldName, _, _ ) ->
            "accessor_" ++ Names.sanitizeName fieldName ++ "_$_" ++ String.fromInt specId

        Nothing ->
            "unknown_$_" ++ String.fromInt specId


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



-- ====== GENERATE EXPRESSION ======


{-| Generate MLIR code for a monomorphic expression.
-}
generateExpr : Ctx.Context -> Mono.MonoExpr -> ExprResult
generateExpr ctx expr =
    case expr of
        Mono.MonoLiteral lit _ ->
            generateLiteral ctx lit

        Mono.MonoVarLocal name _ ->
            let
                ( varName, varType ) =
                    Ctx.lookupVar ctx name
            in
            emptyResult ctx varName varType

        Mono.MonoVarGlobal _ specId monoType ->
            generateVarGlobal ctx specId monoType

        Mono.MonoVarKernel _ home name monoType ->
            generateVarKernel ctx home name monoType

        Mono.MonoList _ items listType ->
            generateList ctx items listType

        Mono.MonoClosure closureInfo body monoType ->
            generateClosure ctx closureInfo body monoType

        Mono.MonoCall _ func args resultType ->
            generateCall ctx func args resultType

        Mono.MonoTailCall name args _ ->
            generateTailCall ctx name args

        Mono.MonoIf branches final _ ->
            generateIf ctx branches final

        Mono.MonoLet def body _ ->
            generateLet ctx def body

        Mono.MonoDestruct destructor body destType ->
            generateDestruct ctx destructor body destType

        Mono.MonoCase scrutinee1 scrutinee2 decider jumps resultType ->
            generateCase ctx scrutinee1 scrutinee2 decider jumps resultType

        Mono.MonoRecordCreate fields layout _ ->
            generateRecordCreate ctx fields layout

        Mono.MonoRecordAccess record fieldName index isUnboxed fieldType ->
            generateRecordAccess ctx record fieldName index isUnboxed fieldType

        Mono.MonoRecordUpdate record updates layout _ ->
            generateRecordUpdate ctx record updates layout

        Mono.MonoTupleCreate _ elements layout _ ->
            generateTupleCreate ctx elements layout

        Mono.MonoUnit ->
            generateUnit ctx



-- ====== LITERAL GENERATION ======


generateLiteral : Ctx.Context -> Mono.Literal -> ExprResult
generateLiteral ctx lit =
    case lit of
        Mono.LBool value ->
            let
                ( var, ctx1 ) =
                    Ctx.freshVar ctx

                ( ctx2, op ) =
                    Ops.arithConstantBool ctx1 var value
            in
            { ops = [ op ]
            , resultVar = var
            , resultType = I1
            , ctx = ctx2, isTerminated = False
            }

        Mono.LInt value ->
            let
                ( var, ctx1 ) =
                    Ctx.freshVar ctx

                ( ctx2, op ) =
                    Ops.arithConstantInt ctx1 var value
            in
            { ops = [ op ]
            , resultVar = var
            , resultType = Types.ecoInt
            , ctx = ctx2, isTerminated = False
            }

        Mono.LFloat value ->
            let
                ( var, ctx1 ) =
                    Ctx.freshVar ctx

                ( ctx2, op ) =
                    Ops.arithConstantFloat ctx1 var value
            in
            { ops = [ op ]
            , resultVar = var
            , resultType = Types.ecoFloat
            , ctx = ctx2, isTerminated = False
            }

        Mono.LChar value ->
            let
                ( var, ctx1 ) =
                    Ctx.freshVar ctx

                codepoint : Int
                codepoint =
                    decodeCharLiteral value

                ( ctx2, op ) =
                    Ops.arithConstantChar ctx1 var codepoint
            in
            { ops = [ op ]
            , resultVar = var
            , resultType = Types.ecoChar
            , ctx = ctx2, isTerminated = False
            }

        Mono.LStr value ->
            let
                ( var, ctx1 ) =
                    Ctx.freshVar ctx

                -- Empty strings must use eco.constant EmptyString (invariant: never heap-allocated)
                ( ctx2, op ) =
                    if value == "" then
                        Ops.ecoConstantEmptyString ctx1 var

                    else
                        Ops.ecoStringLiteral ctx1 var value
            in
            { ops = [ op ]
            , resultVar = var
            , resultType = Types.ecoValue
            , ctx = ctx2, isTerminated = False
            }



-- ====== VARIABLE GENERATION ======


generateVarGlobal : Ctx.Context -> Mono.SpecId -> Mono.MonoType -> ExprResult
generateVarGlobal ctx specId monoType =
    let
        ( var, ctx1 ) =
            Ctx.freshVar ctx

        funcName : String
        funcName =
            specIdToFuncName ctx.registry specId

        -- Use the signature table to determine arity, not just monoType.
        -- This is more reliable because monoType might be a type variable (MVar)
        -- even though the underlying function has parameters.
        maybeSig : Maybe Ctx.FuncSignature
        maybeSig =
            Dict.get specId ctx.signatures
    in
    case maybeSig of
        Just sig ->
            let
                arity : Int
                arity =
                    List.length sig.paramTypes
            in
            if arity == 0 then
                -- Zero-arity function (thunk): call directly instead of creating a PAP.
                -- papCreate requires arity > 0 (num_captured < arity invariant).
                let
                    resultMlirType =
                        Types.monoTypeToMlir sig.returnType

                    ( ctx2, callOp ) =
                        Ops.ecoCallNamed ctx1 var funcName [] resultMlirType
                in
                { ops = [ callOp ]
                , resultVar = var
                , resultType = resultMlirType
                , ctx = ctx2, isTerminated = False
                }

            else
                -- Function-typed global with arity > 0: create a closure (papCreate) with no captures
                -- With typed closure ABI, we use the actual function name directly (no wrapper needed)
                let
                    attrs =
                        Dict.fromList
                            [ ( "function", SymbolRefAttr funcName )
                            , ( "arity", IntAttr Nothing arity )
                            , ( "num_captured", IntAttr Nothing 0 )
                            , ( "unboxed_bitmap", IntAttr Nothing 0 )  -- No captures, so bitmap is 0
                            ]

                    ( ctx2, papOp ) =
                        Ops.mlirOp ctx1 "eco.papCreate"
                            |> Ops.opBuilder.withResults [ ( var, Types.ecoValue ) ]
                            |> Ops.opBuilder.withAttrs attrs
                            |> Ops.opBuilder.build
                in
                { ops = [ papOp ]
                , resultVar = var
                , resultType = Types.ecoValue
                , ctx = ctx2, isTerminated = False
                }

        Nothing ->
            -- No signature found - fall back to monoType-based logic
            -- This should only happen for primitives or special cases
            case monoType of
                Mono.MFunction _ _ ->
                    let
                        arity : Int
                        arity =
                            Types.countTotalArity monoType
                    in
                    if arity == 0 then
                        let
                            resultMlirType =
                                Types.monoTypeToMlir monoType

                            ( ctx2, callOp ) =
                                Ops.ecoCallNamed ctx1 var funcName [] resultMlirType
                        in
                        { ops = [ callOp ]
                        , resultVar = var
                        , resultType = resultMlirType
                        , ctx = ctx2, isTerminated = False
                        }

                    else
                        let
                            attrs =
                                Dict.fromList
                                    [ ( "function", SymbolRefAttr funcName )
                                    , ( "arity", IntAttr Nothing arity )
                                    , ( "num_captured", IntAttr Nothing 0 )
                                    , ( "unboxed_bitmap", IntAttr Nothing 0 )  -- No captures, so bitmap is 0
                                    ]

                            ( ctx2, papOp ) =
                                Ops.mlirOp ctx1 "eco.papCreate"
                                    |> Ops.opBuilder.withResults [ ( var, Types.ecoValue ) ]
                                    |> Ops.opBuilder.withAttrs attrs
                                    |> Ops.opBuilder.build
                        in
                        { ops = [ papOp ]
                        , resultVar = var
                        , resultType = Types.ecoValue
                        , ctx = ctx2, isTerminated = False
                        }

                _ ->
                    -- Non-function type: call the function directly (e.g., zero-arg constructors)
                    let
                        resultMlirType =
                            Types.monoTypeToMlir monoType

                        ( ctx2, callOp ) =
                            Ops.ecoCallNamed ctx1 var funcName [] resultMlirType
                    in
                    { ops = [ callOp ]
                    , resultVar = var
                    , resultType = resultMlirType
                    , ctx = ctx2, isTerminated = False
                    }


generateVarKernel : Ctx.Context -> Name.Name -> Name.Name -> Mono.MonoType -> ExprResult
generateVarKernel ctx home name monoType =
    let
        ( var, ctx1 ) =
            Ctx.freshVar ctx

        kernelName : String
        kernelName =
            "Elm_Kernel_" ++ home ++ "_" ++ name
    in
    -- Check for intrinsic constants (pi, e)
    case Intrinsics.kernelIntrinsic home name [] monoType of
        Just (Intrinsics.ConstantFloat { value }) ->
            let
                ( ctx2, floatOp ) =
                    Ops.arithConstantFloat ctx1 var value
            in
            { ops = [ floatOp ]
            , resultVar = var
            , resultType = Types.ecoFloat
            , ctx = ctx2, isTerminated = False
            }

        Just _ ->
            -- Other intrinsic matched with zero args - but check if it's function-typed
            case monoType of
                Mono.MFunction _ _ ->
                    let
                        arity : Int
                        arity =
                            Types.countTotalArity monoType
                    in
                    if arity == 0 then
                        -- Zero-arity function (thunk): call directly
                        let
                            resultMlirType =
                                Types.monoTypeToMlir monoType

                            ( ctx2, callOp ) =
                                Ops.ecoCallNamed ctx1 var kernelName [] resultMlirType
                        in
                        { ops = [ callOp ]
                        , resultVar = var
                        , resultType = resultMlirType
                        , ctx = ctx2, isTerminated = False
                        }

                    else
                        -- Function-typed kernel with arity > 0: create a closure (papCreate)
                        let
                            attrs =
                                Dict.fromList
                                    [ ( "function", SymbolRefAttr kernelName )
                                    , ( "arity", IntAttr Nothing arity )
                                    , ( "num_captured", IntAttr Nothing 0 )
                                    ]

                            ( ctx2, papOp ) =
                                Ops.mlirOp ctx1 "eco.papCreate"
                                    |> Ops.opBuilder.withResults [ ( var, Types.ecoValue ) ]
                                    |> Ops.opBuilder.withAttrs attrs
                                    |> Ops.opBuilder.build
                        in
                        { ops = [ papOp ]
                        , resultVar = var
                        , resultType = Types.ecoValue
                        , ctx = ctx2, isTerminated = False
                        }

                _ ->
                    -- Non-function type: call directly
                    let
                        resultMlirType =
                            Types.monoTypeToMlir monoType

                        ( ctx2, callOp ) =
                            Ops.ecoCallNamed ctx1 var kernelName [] resultMlirType
                    in
                    { ops = [ callOp ]
                    , resultVar = var
                    , resultType = resultMlirType
                    , ctx = ctx2, isTerminated = False
                    }

        Nothing ->
            -- No intrinsic match - check if this is a function type
            case monoType of
                Mono.MFunction _ _ ->
                    let
                        arity : Int
                        arity =
                            Types.countTotalArity monoType
                    in
                    if arity == 0 then
                        -- Zero-arity function (thunk): call directly
                        let
                            resultMlirType =
                                Types.monoTypeToMlir monoType

                            ( ctx2, callOp ) =
                                Ops.ecoCallNamed ctx1 var kernelName [] resultMlirType
                        in
                        { ops = [ callOp ]
                        , resultVar = var
                        , resultType = resultMlirType
                        , ctx = ctx2, isTerminated = False
                        }

                    else
                        -- Function-typed kernel with arity > 0: create a closure (papCreate)
                        let
                            attrs =
                                Dict.fromList
                                    [ ( "function", SymbolRefAttr kernelName )
                                    , ( "arity", IntAttr Nothing arity )
                                    , ( "num_captured", IntAttr Nothing 0 )
                                    ]

                            ( ctx2, papOp ) =
                                Ops.mlirOp ctx1 "eco.papCreate"
                                    |> Ops.opBuilder.withResults [ ( var, Types.ecoValue ) ]
                                    |> Ops.opBuilder.withAttrs attrs
                                    |> Ops.opBuilder.build
                        in
                        { ops = [ papOp ]
                        , resultVar = var
                        , resultType = Types.ecoValue
                        , ctx = ctx2, isTerminated = False
                        }

                _ ->
                    -- Non-function type: call the kernel directly
                    let
                        resultMlirType =
                            Types.monoTypeToMlir monoType

                        ( ctx2, callOp ) =
                            Ops.ecoCallNamed ctx1 var kernelName [] resultMlirType
                    in
                    { ops = [ callOp ]
                    , resultVar = var
                    , resultType = resultMlirType
                    , ctx = ctx2, isTerminated = False
                    }



-- ====== LIST GENERATION ======


{-| Generate MLIR code for a list literal.
-}
generateList : Ctx.Context -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateList ctx items listType =
    -- Register the list type for the type graph
    let
        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType listType ctx
    in
    case items of
        [] ->
            -- Empty list: use eco.constant Nil (embedded constant, not heap-allocated)
            let
                ( var, ctx1 ) =
                    Ctx.freshVar ctxWithType

                ( ctx2, nilOp ) =
                    Ops.ecoConstantNil ctx1 var
            in
            { ops = [ nilOp ]
            , resultVar = var
            , resultType = Types.ecoValue
            , ctx = ctx2, isTerminated = False
            }

        _ ->
            -- Non-empty list: use eco.constant Nil for tail, eco.construct.list for cons cells.
            -- Now that MonoPath carries ContainerKind, projection ops (eco.project.list_head/tail)
            -- match the Cons layout created by eco.construct.list.
            let
                ( nilVar, ctx1 ) =
                    Ctx.freshVar ctxWithType

                ( ctx2, nilOp ) =
                    Ops.ecoConstantNil ctx1 nilVar

                ( consOps, finalVar, finalCtx ) =
                    List.foldr
                        (\item ( accOps, tailVar, accCtx ) ->
                            let
                                result : ExprResult
                                result =
                                    generateExpr accCtx item

                                -- Box primitive elements before storing in the list
                                ( boxOps, boxedVar, ctx3 ) =
                                    boxToEcoValue result.ctx result.resultVar result.resultType

                                ( consVar, ctx4 ) =
                                    Ctx.freshVar ctx3

                                -- Use eco.construct.list to create cons cells with proper Cons layout
                                -- head_unboxed=false since we box all list elements
                                ( ctx5, consOp ) =
                                    Ops.ecoConstructList ctx4 consVar ( boxedVar, Types.ecoValue ) ( tailVar, Types.ecoValue ) False
                            in
                            ( accOps ++ result.ops ++ boxOps ++ [ consOp ], consVar, ctx5 )
                        )
                        ( [], nilVar, ctx2 )
                        items
            in
            { ops = nilOp :: consOps
            , resultVar = finalVar
            , resultType = Types.ecoValue
            , ctx = finalCtx, isTerminated = False
            }



-- ====== CLOSURE GENERATION ======


{-| Generate MLIR code for a closure.
-}
generateClosure : Ctx.Context -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateClosure ctx closureInfo body monoType =
    let
        -- Generate expressions and track ACTUAL SSA types, not Mono types
        ( captureOps, captureVarsWithTypes, ctx1 ) =
            List.foldl
                (\( _, expr, _ ) ( accOps, accVars, accCtx ) ->
                    let
                        result : ExprResult
                        result =
                            generateExpr accCtx expr
                    in
                    ( accOps ++ result.ops
                    , accVars ++ [ ( result.resultVar, result.resultType ) ]
                    , result.ctx
                    )
                )
                ( [], [], ctx )
                closureInfo.captures

        -- No boxing - use captures with their actual types (typed closure ABI)
        captureVarNames : List String
        captureVarNames =
            List.map Tuple.first captureVarsWithTypes

        captureTypesList : List MlirType
        captureTypesList =
            List.map Tuple.second captureVarsWithTypes

        ( resultVar, ctx2 ) =
            Ctx.freshVar ctx1

        numCaptured : Int
        numCaptured =
            List.length closureInfo.captures

        arity : Int
        arity =
            numCaptured + List.length closureInfo.params

        captureTypes : List ( Name.Name, Mono.MonoType )
        captureTypes =
            List.map (\( name, expr, _ ) -> ( name, Mono.typeOf expr )) closureInfo.captures

        -- Compute unboxed_bitmap from capture types
        -- Only i64 and f64 are unboxable; all other types are boxed (!eco.value)
        unboxedBitmap : Int
        unboxedBitmap =
            List.indexedMap
                (\i ( _, mlirTy ) ->
                    if isUnboxableType mlirTy then
                        Bitwise.shiftLeftBy i 1

                    else
                        0
                )
                captureVarsWithTypes
                |> List.foldl Bitwise.or 0

        -- Use currentLetSiblings if inside a let-rec group, otherwise fall back to varMappings
        -- This ensures closures in mutually recursive let bindings see all siblings
        baseSiblings : Dict.Dict String ( String, MlirType )
        baseSiblings =
            if Dict.isEmpty ctx.currentLetSiblings then
                ctx.varMappings

            else
                ctx.currentLetSiblings

        pendingLambda : Ctx.PendingLambda
        pendingLambda =
            { name = lambdaIdToString closureInfo.lambdaId
            , captures = captureTypes
            , params = closureInfo.params
            , body = body
            , returnType = Mono.typeOf body
            , siblingMappings = baseSiblings
            }
    in
    if arity == 0 then
        -- Zero-arity closure (thunk with no captures): call the lambda directly.
        -- papCreate requires arity > 0 (num_captured < arity invariant).
        let
            ctx3 : Ctx.Context
            ctx3 =
                { ctx2 | pendingLambdas = pendingLambda :: ctx2.pendingLambdas }

            closureResultType =
                Types.monoTypeToMlir monoType

            ( ctx4, callOp ) =
                Ops.ecoCallNamed ctx3 resultVar (lambdaIdToString closureInfo.lambdaId) [] closureResultType
        in
        { ops = captureOps ++ [ callOp ]
        , resultVar = resultVar
        , resultType = closureResultType
        , ctx = ctx4, isTerminated = False
        }

    else
        -- Non-zero arity: create a PAP with captures (typed closure ABI)
        let
            operandTypesAttr =
                if List.isEmpty captureVarNames then
                    Dict.empty

                else
                    -- Use actual capture types (not all !eco.value)
                    Dict.singleton "_operand_types"
                        (ArrayAttr Nothing (List.map TypeAttr captureTypesList))

            papAttrs =
                Dict.union operandTypesAttr
                    (Dict.fromList
                        [ ( "function", SymbolRefAttr (lambdaIdToString closureInfo.lambdaId) )
                        , ( "arity", IntAttr Nothing arity )
                        , ( "num_captured", IntAttr Nothing numCaptured )
                        , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                        ]
                    )

            ( ctx3, papOp ) =
                Ops.mlirOp ctx2 "eco.papCreate"
                    |> Ops.opBuilder.withOperands captureVarNames
                    |> Ops.opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
                    |> Ops.opBuilder.withAttrs papAttrs
                    |> Ops.opBuilder.build

            ctx4 : Ctx.Context
            ctx4 =
                { ctx3 | pendingLambdas = pendingLambda :: ctx3.pendingLambdas }
        in
        { ops = captureOps ++ [ papOp ]
        , resultVar = resultVar
        , resultType = Types.ecoValue
        , ctx = ctx4, isTerminated = False
        }


lambdaIdToString : Mono.LambdaId -> String
lambdaIdToString lambdaId =
    case lambdaId of
        Mono.AnonymousLambda home uid ->
            Names.canonicalToMLIRName home ++ "_lambda_" ++ String.fromInt uid


{-| Check if an MLIR type is unboxable (can be stored as primitive in closures).
Only i64 and f64 are unboxable; all other types must be boxed (!eco.value).
-}
isUnboxableType : MlirType -> Bool
isUnboxableType mlirTy =
    mlirTy == Types.ecoInt || mlirTy == Types.ecoFloat



-- ====== CALL GENERATION ======


{-| Box a value to !eco.value given its MlirType.
If already !eco.value, returns unchanged.
-}
boxToEcoValue : Ctx.Context -> String -> MlirType -> ( List MlirOp, String, Ctx.Context )
boxToEcoValue ctx var mlirTy =
    if Types.isEcoValueType mlirTy then
        ( [], var, ctx )

    else
        let
            ( boxedVar, ctx1 ) =
                Ctx.freshVar ctx

            attrs =
                Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr mlirTy ])

            ( ctx2, boxOp ) =
                Ops.mlirOp ctx1 "eco.box"
                    |> Ops.opBuilder.withOperands [ var ]
                    |> Ops.opBuilder.withResults [ ( boxedVar, Types.ecoValue ) ]
                    |> Ops.opBuilder.withAttrs attrs
                    |> Ops.opBuilder.build
        in
        ( [ boxOp ], boxedVar, ctx2 )


{-| Box or unbox arguments (based on ACTUAL SSA types) to match the
function's expected Mono types.
-}
boxToMatchSignatureTyped :
    Ctx.Context
    -> List ( String, MlirType )
    -> List Mono.MonoType
    -> ( List MlirOp, List ( String, MlirType ), Ctx.Context )
boxToMatchSignatureTyped ctx actualArgs expectedTypes =
    let
        helper :
            ( ( String, MlirType ), Mono.MonoType )
            -> ( List MlirOp, List ( String, MlirType ), Ctx.Context )
            -> ( List MlirOp, List ( String, MlirType ), Ctx.Context )
        helper ( ( var, actualTy ), expectedTy ) ( opsAcc, pairsAcc, ctxAcc ) =
            let
                expectedMlirTy =
                    Types.monoTypeToMlir expectedTy
            in
            if expectedMlirTy == actualTy then
                ( opsAcc, pairsAcc ++ [ ( var, actualTy ) ], ctxAcc )

            else if Types.isEcoValueType expectedMlirTy && not (Types.isEcoValueType actualTy) then
                -- Function expects boxed, we have primitive -> box using actual SSA type
                let
                    ( boxOps, boxedVar, ctx1 ) =
                        boxToEcoValue ctxAcc var actualTy
                in
                ( opsAcc ++ boxOps
                , pairsAcc ++ [ ( boxedVar, Types.ecoValue ) ]
                , ctx1
                )

            else if not (Types.isEcoValueType expectedMlirTy) && Types.isEcoValueType actualTy then
                -- Function expects primitive, we have boxed -> unbox to expected primitive type
                let
                    ( unboxOps, unboxedVar, ctx1 ) =
                        Intrinsics.unboxToType ctxAcc var expectedMlirTy
                in
                ( opsAcc ++ unboxOps
                , pairsAcc ++ [ ( unboxedVar, expectedMlirTy ) ]
                , ctx1
                )

            else
                -- No boxing solution (e.g. i64 vs f64) - use actual type for now
                ( opsAcc, pairsAcc ++ [ ( var, actualTy ) ], ctxAcc )
    in
    List.foldl helper ( [], [], ctx ) (List.map2 Tuple.pair actualArgs expectedTypes)


{-| Coerce an expression result to a desired MLIR type by inserting
boxing/unboxing ops when the difference is only boxed vs unboxed.
Handles both directions:

  - primitive -> !eco.value (box)
  - !eco.value -> primitive (unbox)

-}
coerceResultToType : Ctx.Context -> String -> MlirType -> MlirType -> ( List MlirOp, String, Ctx.Context )
coerceResultToType ctx var actualTy expectedTy =
    if actualTy == expectedTy then
        -- No coercion needed
        ( [], var, ctx )

    else if Types.isEcoValueType expectedTy && not (Types.isEcoValueType actualTy) then
        -- Need primitive -> boxed
        boxToEcoValue ctx var actualTy

    else if not (Types.isEcoValueType expectedTy) && Types.isEcoValueType actualTy then
        -- Need boxed -> primitive
        Intrinsics.unboxToType ctx var expectedTy

    else
        -- Types don't match and no boxing/unboxing solution
        -- This indicates a monomorphization bug - primitive type mismatches
        -- (e.g., i64 vs f64) should have been resolved upstream
        crash <|
            "coerceResultToType: cannot coerce "
                ++ Types.mlirTypeToString actualTy
                ++ " to "
                ++ Types.mlirTypeToString expectedTy
                ++ " for variable "
                ++ var


{-| Generate MLIR code for a function call.
-}
generateCall : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateCall ctx func args resultType =
    -- If the result type is still a function, this is a partial application.
    -- Route through the closure path to avoid direct calls with insufficient args.
    if Types.isFunctionType resultType then
        generateClosureApplication ctx func args resultType

    else
        generateSaturatedCall ctx func args resultType


{-| Generate a partial application where the result is still a closure.
This creates a closure via papExtend rather than attempting a direct call.
-}
generateClosureApplication : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateClosureApplication ctx func args resultType =
    let
        funcResult : ExprResult
        funcResult =
            generateExpr ctx func

        -- Result is a closure (!eco.value)
        expectedType =
            Types.monoTypeToMlir resultType
    in
    -- If the function result is not a closure (e.g., a zero-arity thunk was
    -- already evaluated), and we're calling with no args, just return the value.
    -- This handles: let f = \() -> 42 in f
    -- where f is already evaluated to i64, and "calling" with no args is a no-op.
    if not (Types.isEcoValueType funcResult.resultType) && List.isEmpty args then
        -- Already evaluated - just return the value, coercing if needed
        let
            ( coerceOps, finalVar, ctx1 ) =
                coerceResultToType funcResult.ctx funcResult.resultVar funcResult.resultType expectedType
        in
        { ops = funcResult.ops ++ coerceOps
        , resultVar = finalVar
        , resultType = expectedType
        , ctx = ctx1, isTerminated = False
        }

    else
        -- Normal partial application via papExtend (typed closure ABI)
        let
            -- Use generateExprListTyped to get actual SSA types
            ( argOps, argsWithTypes, ctx1 ) =
                generateExprListTyped funcResult.ctx args

            -- No boxing - use args with their actual types (typed closure ABI)
            argVarNames : List String
            argVarNames =
                List.map Tuple.first argsWithTypes

            argTypesList : List MlirType
            argTypesList =
                List.map Tuple.second argsWithTypes

            ( resVar, ctx2 ) =
                Ctx.freshVar ctx1

            allOperandNames : List String
            allOperandNames =
                funcResult.resultVar :: argVarNames

            -- Use actual types for all operands (typed closure ABI)
            allOperandTypes : List MlirType
            allOperandTypes =
                funcResult.resultType :: argTypesList

            -- Compute newargs_unboxed_bitmap from arg types
            newargsUnboxedBitmap : Int
            newargsUnboxedBitmap =
                List.indexedMap
                    (\i ( _, mlirTy ) ->
                        if isUnboxableType mlirTy then
                            Bitwise.shiftLeftBy i 1

                        else
                            0
                    )
                    argsWithTypes
                    |> List.foldl Bitwise.or 0

            -- Compute arity from the FUNCTION type, not the result type
            funcType : Mono.MonoType
            funcType =
                Mono.typeOf func

            remainingArity : Int
            remainingArity =
                Types.functionArity funcType

            -- papExtend handles both partial and saturated cases
            papExtendAttrs =
                Dict.fromList
                    [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                    , ( "remaining_arity", IntAttr Nothing remainingArity )
                    , ( "newargs_unboxed_bitmap", IntAttr Nothing newargsUnboxedBitmap )
                    ]

            ( ctx3, papExtendOp ) =
                Ops.mlirOp ctx2 "eco.papExtend"
                    |> Ops.opBuilder.withOperands allOperandNames
                    |> Ops.opBuilder.withResults [ ( resVar, Types.ecoValue ) ]
                    |> Ops.opBuilder.withAttrs papExtendAttrs
                    |> Ops.opBuilder.build
        in
        { ops = funcResult.ops ++ argOps ++ [ papExtendOp ]
        , resultVar = resVar
        , resultType = expectedType
        , ctx = ctx3, isTerminated = False
        }


{-| Generate a saturated function call where all arguments are provided.
-}
generateSaturatedCall : Ctx.Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateSaturatedCall ctx func args resultType =
    case func of
        Mono.MonoVarGlobal _ specId funcType ->
            let
                -- Use generateExprListTyped to get actual SSA types
                ( argOps, argsWithTypes, ctx1 ) =
                    generateExprListTyped ctx args

                argVars : List String
                argVars =
                    List.map Tuple.first argsWithTypes

                argTypes : List Mono.MonoType
                argTypes =
                    List.map Mono.typeOf args

                -- Check if this is a call to a core module function
                maybeCoreInfo : Maybe ( String, String )
                maybeCoreInfo =
                    case Mono.lookupSpecKey specId ctx.registry of
                        Just ( Mono.Global (IO.Canonical pkg moduleName) name, _, _ ) ->
                            if pkg == Pkg.core then
                                Just ( moduleName, name )

                            else
                                Nothing

                        Just ( Mono.Accessor _, _, _ ) ->
                            -- Accessors are not core functions
                            Nothing

                        Nothing ->
                            Nothing
            in
            case maybeCoreInfo of
                Just ( moduleName, name ) ->
                    -- This is a core module function - check for intrinsic
                    case Intrinsics.kernelIntrinsic moduleName name argTypes resultType of
                        Just intrinsic ->
                            -- Generate intrinsic operation directly
                            let
                                ( resVar, ctx2 ) =
                                    Ctx.freshVar ctx1

                                ( ctx3, intrinsicOp ) =
                                    Intrinsics.generateIntrinsicOp ctx2 intrinsic resVar argVars

                                intrinsicResultType =
                                    Intrinsics.intrinsicResultMlirType intrinsic
                            in
                            { ops = argOps ++ [ intrinsicOp ]
                            , resultVar = resVar
                            , resultType = intrinsicResultType
                            , ctx = ctx3, isTerminated = False
                            }

                        Nothing ->
                            -- No intrinsic match - check if we should use kernel or compiled function
                            if Ctx.hasKernelImplementation moduleName name then
                                -- Fall back to kernel call (e.g., negate with boxed values)
                                let
                                    sig : Ctx.FuncSignature
                                    sig =
                                        Ctx.kernelFuncSignatureFromType funcType

                                    -- Use boxToMatchSignatureTyped with actual SSA types
                                    ( boxOps, argVarPairs, ctx1b ) =
                                        boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

                                    ( resVar, ctx2 ) =
                                        Ctx.freshVar ctx1b

                                    kernelName : String
                                    kernelName =
                                        "Elm_Kernel_" ++ moduleName ++ "_" ++ name

                                    callResultType =
                                        Types.monoTypeToMlir sig.returnType

                                    ( ctx3, callOp ) =
                                        Ops.ecoCallNamed ctx2 resVar kernelName argVarPairs callResultType
                                in
                                { ops = argOps ++ boxOps ++ [ callOp ]
                                , resultVar = resVar
                                , resultType = callResultType
                                , ctx = ctx3, isTerminated = False
                                }

                            else
                                -- Fall back to compiled function call (e.g., min, max, abs, compare)
                                let
                                    funcName : String
                                    funcName =
                                        specIdToFuncName ctx.registry specId

                                    maybeSig : Maybe Ctx.FuncSignature
                                    maybeSig =
                                        Dict.get specId ctx.signatures

                                    ( boxOps, argVarPairs, ctx1b ) =
                                        case maybeSig of
                                            Just sig ->
                                                -- Use boxToMatchSignatureTyped with actual SSA types
                                                boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

                                            Nothing ->
                                                -- No signature: use actual SSA types
                                                ( [], argsWithTypes, ctx1 )

                                    ( resultVar, ctx2 ) =
                                        Ctx.freshVar ctx1b

                                    callResultType =
                                        Types.monoTypeToMlir resultType

                                    ( ctx3, callOp ) =
                                        Ops.ecoCallNamed ctx2 resultVar funcName argVarPairs callResultType
                                in
                                { ops = argOps ++ boxOps ++ [ callOp ]
                                , resultVar = resultVar
                                , resultType = callResultType
                                , ctx = ctx3, isTerminated = False
                                }

                Nothing ->
                    -- Regular function call (not a core module)
                    let
                        funcName : String
                        funcName =
                            specIdToFuncName ctx.registry specId

                        -- Look up the function signature to determine expected parameter types
                        maybeSig : Maybe Ctx.FuncSignature
                        maybeSig =
                            Dict.get specId ctx.signatures

                        -- Use boxToMatchSignatureTyped with actual SSA types
                        ( boxOps, argVarPairs, ctx1b ) =
                            case maybeSig of
                                Just sig ->
                                    boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

                                Nothing ->
                                    -- No signature: use actual SSA types
                                    ( [], argsWithTypes, ctx1 )

                        ( resultVar, ctx2 ) =
                            Ctx.freshVar ctx1b

                        callResultType =
                            Types.monoTypeToMlir resultType

                        ( ctx3, callOp ) =
                            Ops.ecoCallNamed ctx2 resultVar funcName argVarPairs callResultType
                    in
                    { ops = argOps ++ boxOps ++ [ callOp ]
                    , resultVar = resultVar
                    , resultType = callResultType
                    , ctx = ctx3, isTerminated = False
                    }

        Mono.MonoVarKernel _ home name funcType ->
            let
                -- Use generateExprListTyped to get actual SSA types
                ( argOps, argsWithTypes, ctx1 ) =
                    generateExprListTyped ctx args

                argTypes : List Mono.MonoType
                argTypes =
                    List.map Mono.typeOf args
            in
            case ( home, name, argsWithTypes ) of
                ( "Basics", "logBase", [ ( baseVar, baseType ), ( xVar, xType ) ] ) ->
                    let
                        -- Unbox baseVar if needed
                        ( unboxBaseOps, unboxedBaseVar, ctx1a ) =
                            if Types.isEcoValueType baseType then
                                Intrinsics.unboxToType ctx1 baseVar F64

                            else
                                ( [], baseVar, ctx1 )

                        -- Unbox xVar if needed
                        ( unboxXOps, unboxedXVar, ctx1b ) =
                            if Types.isEcoValueType xType then
                                Intrinsics.unboxToType ctx1a xVar F64

                            else
                                ( [], xVar, ctx1a )

                        ( logXVar, ctx2 ) =
                            Ctx.freshVar ctx1b

                        ( logBaseVar, ctx3 ) =
                            Ctx.freshVar ctx2

                        ( resVar, _ ) =
                            Ctx.freshVar ctx3

                        ( ctx5, logXOp ) =
                            Ops.ecoUnaryOp ctx2 "eco.float.log" logXVar ( unboxedXVar, F64 ) F64

                        ( ctx6, logBaseOp ) =
                            Ops.ecoUnaryOp ctx5 "eco.float.log" logBaseVar ( unboxedBaseVar, F64 ) F64

                        ( ctx7, divOp ) =
                            Ops.ecoBinaryOp ctx6 "eco.float.div" resVar ( logXVar, F64 ) ( logBaseVar, F64 ) F64
                    in
                    { ops = argOps ++ unboxBaseOps ++ unboxXOps ++ [ logXOp, logBaseOp, divOp ]
                    , resultVar = resVar
                    , resultType = Types.ecoFloat
                    , ctx = ctx7, isTerminated = False
                    }

                ( "Debug", "log", [ ( labelVar, _ ), ( valueVar, valueType ) ] ) ->
                    -- Special handling for Debug.log with typed output
                    -- Emit eco.dbg with arg_type_ids, then return the value
                    let
                        -- Get the type of the value being logged
                        valueMonoType : Mono.MonoType
                        valueMonoType =
                            case args of
                                [ _, valueExpr ] ->
                                    Mono.typeOf valueExpr

                                _ ->
                                    Mono.MUnit

                        -- Get or create a type ID for this type
                        ( typeId, ctx1b ) =
                            Ctx.getOrCreateTypeIdForMonoType valueMonoType ctx1

                        -- Box the value if needed for eco.dbg
                        ( boxOps, boxedValueVar, ctx1c ) =
                            if Types.isEcoValueType valueType then
                                ( [], valueVar, ctx1b )

                            else
                                let
                                    ( boxVar, ctx1c_ ) =
                                        Ctx.freshVar ctx1b

                                    boxAttrs =
                                        Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr valueType ])

                                    ( ctx1c__, boxOp ) =
                                        Ops.mlirOp ctx1c_ "eco.box"
                                            |> Ops.opBuilder.withOperands [ valueVar ]
                                            |> Ops.opBuilder.withResults [ ( boxVar, Types.ecoValue ) ]
                                            |> Ops.opBuilder.withAttrs boxAttrs
                                            |> Ops.opBuilder.build
                                in
                                ( [ boxOp ], boxVar, ctx1c__ )

                        -- Create eco.dbg op with arg_type_ids
                        -- We only pass the value with its type_id
                        -- The label is printed separately by the runtime
                        ( ctx2, dbgOp ) =
                            Ops.mlirOp ctx1c "eco.dbg"
                                |> Ops.opBuilder.withOperands [ labelVar, boxedValueVar ]
                                |> Ops.opBuilder.withAttrs
                                    (Dict.fromList
                                        [ ( "_operand_types"
                                          , ArrayAttr Nothing [ TypeAttr Types.ecoValue, TypeAttr Types.ecoValue ]
                                          )
                                        , ( "arg_type_ids"
                                          , ArrayAttr (Just I64)
                                                [ IntAttr Nothing -1 -- -1 for string label (to be printed as string)
                                                , IntAttr Nothing typeId -- typeId for value
                                                ]
                                          )
                                        ]
                                    )
                                |> Ops.opBuilder.build
                    in
                    { ops = argOps ++ boxOps ++ [ dbgOp ]
                    , resultVar = boxedValueVar -- Return the value (boxed)
                    , resultType = Types.ecoValue
                    , ctx = ctx2, isTerminated = False
                    }

                _ ->
                    case Intrinsics.kernelIntrinsic home name argTypes resultType of
                        Just intrinsic ->
                            let
                                -- Unbox arguments if needed (e.g., !eco.value -> i64)
                                ( unboxOps, unboxedArgVars, ctx1b ) =
                                    Intrinsics.unboxArgsForIntrinsic ctx1 argsWithTypes intrinsic

                                ( resVar, ctx2 ) =
                                    Ctx.freshVar ctx1b

                                ( ctx3, intrinsicOp ) =
                                    Intrinsics.generateIntrinsicOp ctx2 intrinsic resVar unboxedArgVars

                                intrinsicResType =
                                    Intrinsics.intrinsicResultMlirType intrinsic
                            in
                            { ops = argOps ++ unboxOps ++ [ intrinsicOp ]
                            , resultVar = resVar
                            , resultType = intrinsicResType
                            , ctx = ctx3, isTerminated = False
                            }

                        Nothing ->
                            -- Generic kernel ABI path derived solely from MonoType.
                            -- Polymorphic kernels have MVar in their funcType, which
                            -- Types.monoTypeToMlir maps to !eco.value, so they naturally
                            -- get all-boxed ABI without name-based checks.
                            let
                                elmSig : Ctx.FuncSignature
                                elmSig =
                                    Ctx.kernelFuncSignatureFromType funcType

                                -- Use boxToMatchSignatureTyped with actual SSA types
                                ( boxOps, argVarPairs, ctx1b ) =
                                    boxToMatchSignatureTyped ctx1 argsWithTypes elmSig.paramTypes

                                ( resVar, ctx2 ) =
                                    Ctx.freshVar ctx1b

                                kernelName : String
                                kernelName =
                                    "Elm_Kernel_" ++ home ++ "_" ++ name

                                resultMlirType : MlirType
                                resultMlirType =
                                    Types.monoTypeToMlir elmSig.returnType

                                ( ctx3, callOp ) =
                                    Ops.ecoCallNamed ctx2 resVar kernelName argVarPairs resultMlirType
                            in
                            { ops = argOps ++ boxOps ++ [ callOp ]
                            , resultVar = resVar
                            , resultType = resultMlirType
                            , ctx = ctx3, isTerminated = False
                            }

        Mono.MonoVarLocal name funcType ->
            let
                ( funcVarName, funcVarType ) =
                    Ctx.lookupVar ctx name

                expectedType =
                    Types.monoTypeToMlir resultType
            in
            -- If the function variable is not a closure (e.g., a zero-arity thunk was
            -- already evaluated), and we're calling with no args, just return the value.
            -- This handles: let f = \() -> 42 in f()
            -- where f is already evaluated to i64, not a closure.
            if not (Types.isEcoValueType funcVarType) && List.isEmpty args then
                -- Already evaluated - just return the value, coercing if needed
                let
                    ( coerceOps, finalVar, ctx1 ) =
                        coerceResultToType ctx funcVarName funcVarType expectedType
                in
                { ops = coerceOps
                , resultVar = finalVar
                , resultType = expectedType
                , ctx = ctx1, isTerminated = False
                }

            else
                -- Normal closure call via papExtend (typed closure ABI)
                let
                    -- Use generateExprListTyped to get actual SSA types
                    ( argOps, argsWithTypes, ctx1 ) =
                        generateExprListTyped ctx args

                    argVarNames : List String
                    argVarNames =
                        List.map Tuple.first argsWithTypes

                    argTypesList : List MlirType
                    argTypesList =
                        List.map Tuple.second argsWithTypes

                    ( resVar, ctx2 ) =
                        Ctx.freshVar ctx1

                    allOperandNames : List String
                    allOperandNames =
                        funcVarName :: argVarNames

                    -- Use actual SSA types for all operands
                    allOperandTypes : List MlirType
                    allOperandTypes =
                        funcVarType :: argTypesList

                    -- Compute unboxed bitmap for new args
                    newargsUnboxedBitmap : Int
                    newargsUnboxedBitmap =
                        List.indexedMap
                            (\i ( _, mlirTy ) ->
                                if isUnboxableType mlirTy then
                                    Bitwise.shiftLeftBy i 1

                                else
                                    0
                            )
                            argsWithTypes
                            |> List.foldl Bitwise.or 0

                    -- Compute arity from the FUNCTION type, not the result type
                    remainingArity : Int
                    remainingArity =
                        Types.functionArity funcType

                    -- papExtend handles both partial and saturated cases
                    papExtendAttrs =
                        Dict.fromList
                            [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                            , ( "remaining_arity", IntAttr Nothing remainingArity )
                            , ( "newargs_unboxed_bitmap", IntAttr Nothing newargsUnboxedBitmap )
                            ]

                    ( ctx3, papExtendOp ) =
                        Ops.mlirOp ctx2 "eco.papExtend"
                            |> Ops.opBuilder.withOperands allOperandNames
                            |> Ops.opBuilder.withResults [ ( resVar, expectedType ) ]
                            |> Ops.opBuilder.withAttrs papExtendAttrs
                            |> Ops.opBuilder.build
                in
                { ops = argOps ++ [ papExtendOp ]
                , resultVar = resVar
                , resultType = expectedType
                , ctx = ctx3, isTerminated = False
                }

        _ ->
            let
                funcResult : ExprResult
                funcResult =
                    generateExpr ctx func

                expectedType =
                    Types.monoTypeToMlir resultType
            in
            -- If the function result is not a closure (e.g., a zero-arity thunk was
            -- already evaluated), and we're calling with no args, just return the value.
            if not (Types.isEcoValueType funcResult.resultType) && List.isEmpty args then
                -- Already evaluated - just return the value, coercing if needed
                let
                    ( coerceOps, finalVar, ctx1 ) =
                        coerceResultToType funcResult.ctx funcResult.resultVar funcResult.resultType expectedType
                in
                { ops = funcResult.ops ++ coerceOps
                , resultVar = finalVar
                , resultType = expectedType
                , ctx = ctx1, isTerminated = False
                }

            else
                -- Normal closure call via papExtend (typed closure ABI)
                let
                    -- Use generateExprListTyped to get actual SSA types
                    ( argOps, argsWithTypes, ctx1 ) =
                        generateExprListTyped funcResult.ctx args

                    argVarNames : List String
                    argVarNames =
                        List.map Tuple.first argsWithTypes

                    argTypesList : List MlirType
                    argTypesList =
                        List.map Tuple.second argsWithTypes

                    ( resVar, ctx2 ) =
                        Ctx.freshVar ctx1

                    allOperandNames : List String
                    allOperandNames =
                        funcResult.resultVar :: argVarNames

                    -- Use actual SSA types for all operands
                    allOperandTypes : List MlirType
                    allOperandTypes =
                        funcResult.resultType :: argTypesList

                    -- Compute unboxed bitmap for new args
                    newargsUnboxedBitmap : Int
                    newargsUnboxedBitmap =
                        List.indexedMap
                            (\i ( _, mlirTy ) ->
                                if isUnboxableType mlirTy then
                                    Bitwise.shiftLeftBy i 1

                                else
                                    0
                            )
                            argsWithTypes
                            |> List.foldl Bitwise.or 0

                    -- Compute arity from the FUNCTION type, not the result type
                    funcType : Mono.MonoType
                    funcType =
                        Mono.typeOf func

                    remainingArity : Int
                    remainingArity =
                        Types.functionArity funcType

                    -- papExtend handles both partial and saturated cases
                    papExtendAttrs =
                        Dict.fromList
                            [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                            , ( "remaining_arity", IntAttr Nothing remainingArity )
                            , ( "newargs_unboxed_bitmap", IntAttr Nothing newargsUnboxedBitmap )
                            ]

                    ( ctx3, papExtendOp ) =
                        Ops.mlirOp ctx2 "eco.papExtend"
                            |> Ops.opBuilder.withOperands allOperandNames
                            |> Ops.opBuilder.withResults [ ( resVar, expectedType ) ]
                            |> Ops.opBuilder.withAttrs papExtendAttrs
                            |> Ops.opBuilder.build
                in
                { ops = funcResult.ops ++ argOps ++ [ papExtendOp ]
                , resultVar = resVar
                , resultType = expectedType
                , ctx = ctx3, isTerminated = False
                }


{-| Generate expressions and return their ACTUAL MLIR types (not from Mono.typeOf).
This is important when the Mono types may be incorrect/stale, but the generated
SSA values have correct types.
-}
generateExprListTyped : Ctx.Context -> List Mono.MonoExpr -> ( List MlirOp, List ( String, MlirType ), Ctx.Context )
generateExprListTyped ctx exprs =
    List.foldl
        (\expr ( accOps, accVarsWithTypes, accCtx ) ->
            let
                result : ExprResult
                result =
                    generateExpr accCtx expr
            in
            ( accOps ++ result.ops
            , accVarsWithTypes ++ [ ( result.resultVar, result.resultType ) ]
            , result.ctx
            )
        )
        ( [], [], ctx )
        exprs


{-| Box arguments to !eco.value using their ACTUAL MLIR types.
This is safer than boxArgsIfNeeded because it uses the real SSA types
instead of relying on potentially incorrect Mono types.
-}
boxArgsWithMlirTypes :
    Ctx.Context
    -> List ( String, MlirType )
    -> ( List MlirOp, List String, Ctx.Context )
boxArgsWithMlirTypes ctx args =
    List.foldl
        (\( var, mlirTy ) ( opsAcc, varsAcc, ctxAcc ) ->
            let
                ( moreOps, boxedVar, ctx1 ) =
                    boxToEcoValue ctxAcc var mlirTy
            in
            ( opsAcc ++ moreOps, varsAcc ++ [ boxedVar ], ctx1 )
        )
        ( [], [], ctx )
        args



-- ====== TAIL CALL GENERATION ======


{-| Generate MLIR code for a tail call.
-}
generateTailCall : Ctx.Context -> Name.Name -> List ( Name.Name, Mono.MonoExpr ) -> ExprResult
generateTailCall ctx name args =
    let
        -- Generate arguments and track actual SSA types
        ( argsOps, argsWithTypes, ctx1 ) =
            List.foldl
                (\( _, expr ) ( accOps, accVarsWithTypes, accCtx ) ->
                    let
                        result : ExprResult
                        result =
                            generateExpr accCtx expr
                    in
                    ( accOps ++ result.ops
                    , accVarsWithTypes ++ [ ( result.resultVar, result.resultType ) ]
                    , result.ctx
                    )
                )
                ( [], [], ctx )
                args

        -- Extract variable names and their actual SSA types
        argVarNames : List String
        argVarNames =
            List.map Tuple.first argsWithTypes

        argVarTypes : List MlirType
        argVarTypes =
            List.map Tuple.second argsWithTypes

        -- eco.jump target is a joinpoint ID (integer), not a symbol name.
        -- For tail-recursive functions, the joinpoint ID is 0.
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
    -- eco.jump is a terminator - it does not produce a result value.
    -- INVARIANT: resultVar is meaningless when isTerminated=True, must not be used.
    { ops = argsOps ++ [ jumpOp ]
    , resultVar = "" -- INVARIANT: meaningless when isTerminated=True
    , resultType = Types.ecoValue
    , ctx = ctx2
    , isTerminated = True -- eco.jump is a terminator
    }



-- ====== IF GENERATION ======


{-| Generate if expressions using eco.case on Bool.

Compiles `if c1 then t1 else if c2 then t2 else ... final` to nested
eco.case operations on boolean conditions.

-}
generateIf : Ctx.Context -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> Mono.MonoExpr -> ExprResult
generateIf ctx branches final =
    case branches of
        [] ->
            generateExpr ctx final

        ( condExpr, thenExpr ) :: restBranches ->
            let
                -- Evaluate condition to Bool (produces i1)
                condRes =
                    generateExpr ctx condExpr

                condVar =
                    condRes.resultVar

                -- Generate then branch first to get its actual result type
                thenRes =
                    generateExpr condRes.ctx thenExpr
            in
            -- Check if then branch is terminated (e.g., tail call with eco.jump).
            -- If so, we can't use scf.if which requires both branches to yield.
            -- Fall back to eco.case which supports terminated regions.
            if thenRes.isTerminated then
                generateIfWithTerminatedBranch condRes.ctx condVar thenRes restBranches final condRes.ops

            else
                -- Then branch produces a value, check else branch
                let
                    -- Use the then branch's actual SSA type as the result type
                    resultMlirType =
                        thenRes.resultType

                    -- Coerce then result to target type if needed
                    ( thenCoerceOps, thenFinalVar, thenFinalCtx ) =
                        coerceResultToType thenRes.ctx thenRes.resultVar thenRes.resultType resultMlirType

                    ( ctx1, thenYieldOp ) =
                        Ops.scfYield thenFinalCtx thenFinalVar resultMlirType

                    thenRegion =
                        Ops.mkRegion [] (thenRes.ops ++ thenCoerceOps) thenYieldOp

                    -- Generate else branch (recursive if or final)
                    elseRes =
                        generateIf ctx1 restBranches final
                in
                if elseRes.isTerminated then
                    -- Else branch is terminated - use eco.case instead
                    generateIfWithTerminatedElse condRes.ctx condVar thenRes elseRes resultMlirType condRes.ops

                else
                    -- Normal case: both branches produce values, use scf.if
                    let
                        -- Coerce else result to match then branch's type
                        ( elseCoerceOps, elseFinalVar, elseFinalCtx ) =
                            coerceResultToType elseRes.ctx elseRes.resultVar elseRes.resultType resultMlirType

                        ( ctx2, elseYieldOp ) =
                            Ops.scfYield elseFinalCtx elseFinalVar resultMlirType

                        elseRegion =
                            Ops.mkRegion [] (elseRes.ops ++ elseCoerceOps) elseYieldOp

                        -- Allocate result variable for scf.if
                        ( ifResultVar, ctx2b ) =
                            Ctx.freshVar ctx2

                        -- scf.if with i1 condition directly (avoids eco.get_tag on embedded constants)
                        ( ctx3, ifOp ) =
                            Ops.scfIf ctx2b condVar ifResultVar thenRegion elseRegion resultMlirType
                    in
                    { ops = condRes.ops ++ [ ifOp ]
                    , resultVar = ifResultVar
                    , resultType = resultMlirType
                    , ctx = ctx3, isTerminated = False
                    }


{-| Generate if-then-else using eco.case when the then branch is terminated.
-}
generateIfWithTerminatedBranch : Ctx.Context -> String -> ExprResult -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> Mono.MonoExpr -> List MlirOp -> ExprResult
generateIfWithTerminatedBranch ctx condVar thenRes restBranches final condOps =
    let
        -- Build then region - it already has a terminator
        thenRegion =
            mkRegionFromOps thenRes.ops

        -- Generate else branch with proper context (from then result)
        elseRes =
            generateIf thenRes.ctx restBranches final

        -- Determine result type from else branch (then is terminated)
        resultMlirType =
            if elseRes.isTerminated then
                Types.ecoValue
            else
                elseRes.resultType

        -- Build else region
        ( elseRegion, ctxAfterElse ) =
            if elseRes.isTerminated then
                ( mkRegionFromOps elseRes.ops, elseRes.ctx )
            else
                let
                    ( coerceOps, finalVar, coerceCtx ) =
                        coerceResultToType elseRes.ctx elseRes.resultVar elseRes.resultType resultMlirType

                    ( retCtx, retOp ) =
                        Ops.ecoReturn coerceCtx finalVar resultMlirType
                in
                ( Ops.mkRegion [] (elseRes.ops ++ coerceOps) retOp, retCtx )

        -- eco.case on i1: tag 1 for True (then), tag 0 for False (else)
        ( ctxFinal, caseOp ) =
            Ops.ecoCase ctxAfterElse condVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] [ resultMlirType ]
    in
    -- eco.case is a terminator, so the whole expression is terminated.
    -- There is no single resultVar - exits happen via eco.return/eco.jump within regions.
    { ops = condOps ++ [ caseOp ]
    , resultVar = "" -- No result, eco.case is a terminator
    , resultType = resultMlirType
    , ctx = ctxFinal
    , isTerminated = True -- eco.case is a terminator
    }


{-| Generate if-then-else using eco.case when the else branch is terminated.
The then branch has already been processed and yields a value.
-}
generateIfWithTerminatedElse : Ctx.Context -> String -> ExprResult -> ExprResult -> MlirType -> List MlirOp -> ExprResult
generateIfWithTerminatedElse ctx condVar thenRes elseRes resultMlirType condOps =
    let
        -- Build then region with eco.return (not terminated)
        ( thenCoerceOps, thenFinalVar, thenCoerceCtx ) =
            coerceResultToType thenRes.ctx thenRes.resultVar thenRes.resultType resultMlirType

        ( thenRetCtx, thenRetOp ) =
            Ops.ecoReturn thenCoerceCtx thenFinalVar resultMlirType

        thenRegion =
            Ops.mkRegion [] (thenRes.ops ++ thenCoerceOps) thenRetOp

        -- Else region already has a terminator
        elseRegion =
            mkRegionFromOps elseRes.ops

        -- eco.case on i1: tag 1 for True (then), tag 0 for False (else)
        ( ctxFinal, caseOp ) =
            Ops.ecoCase elseRes.ctx condVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] [ resultMlirType ]
    in
    -- eco.case is a terminator, so the whole expression is terminated.
    -- There is no single resultVar - exits happen via eco.return/eco.jump within regions.
    { ops = condOps ++ [ caseOp ]
    , resultVar = "" -- No result, eco.case is a terminator
    , resultType = resultMlirType
    , ctx = ctxFinal
    , isTerminated = True -- eco.case is a terminator
    }



-- ====== LET GENERATION ======


{-| Collect all names bound in a chain of nested Let expressions.
This is used to add placeholder mappings for mutually recursive definitions
before generating any closures.
-}
collectLetBoundNames : Mono.MonoExpr -> List Name.Name
collectLetBoundNames expr =
    case expr of
        Mono.MonoLet def body _ ->
            let
                defName =
                    case def of
                        Mono.MonoDef name _ ->
                            name

                        Mono.MonoTailDef name _ _ ->
                            name
            in
            defName :: collectLetBoundNames body

        _ ->
            []


{-| Add placeholder mappings for a list of names.
These placeholders allow closures to reference sibling functions
in mutually recursive let-rec definitions.
-}
addPlaceholderMappings : List Name.Name -> Ctx.Context -> Ctx.Context
addPlaceholderMappings names ctx =
    List.foldl
        (\name acc ->
            -- Only add placeholder if not already in mappings
            case Dict.get name acc.varMappings of
                Just _ ->
                    acc

                Nothing ->
                    Ctx.addVarMapping name ("%" ++ name) Types.ecoValue acc
        )
        ctx
        names


{-| Generate MLIR code for a let expression.
-}
generateLet : Ctx.Context -> Mono.MonoDef -> Mono.MonoExpr -> ExprResult
generateLet ctx def body =
    -- For mutually recursive definitions, add placeholder mappings for all
    -- names in the Let chain before generating any closures.
    -- We also set currentLetSiblings so that closures created in this group
    -- capture the correct sibling environment.
    let
        boundNames =
            collectLetBoundNames (Mono.MonoLet def body Mono.MUnit)

        -- Save outer siblings for restoration on exit (lexical scoping)
        outerSiblings =
            ctx.currentLetSiblings

        -- Build placeholder mappings for the whole let-group
        groupVarMappings =
            addPlaceholderMappings boundNames ctx

        -- Set both varMappings and currentLetSiblings to the group environment
        ctxWithPlaceholders =
            { groupVarMappings | currentLetSiblings = groupVarMappings.varMappings }
    in
    case def of
        Mono.MonoDef name expr ->
            let
                exprResult : ExprResult
                exprResult =
                    generateExpr ctxWithPlaceholders expr

                -- Instead of creating an eco.construct wrapper, just add a mapping
                -- from the let-bound name to the expression's result variable.
                -- This preserves the original type and avoids boxing issues.
                ctx1 : Ctx.Context
                ctx1 =
                    Ctx.addVarMapping name exprResult.resultVar exprResult.resultType exprResult.ctx

                bodyResult : ExprResult
                bodyResult =
                    generateExpr ctx1 body

                -- Restore outer siblings on exit from the let-rec group
                bodyCtx : Ctx.Context
                bodyCtx =
                    bodyResult.ctx

                ctxOut : Ctx.Context
                ctxOut =
                    { bodyCtx | currentLetSiblings = outerSiblings }

                -- Propagate isTerminated when:
                -- 1. The bound expression is terminated (eco.case, eco.jump), AND
                --    the body is trivial (just returning the let-bound variable, so no body ops)
                -- 2. OR the body itself is terminated
                -- In these cases, the case alternatives already contain the correct returns.
                finalIsTerminated =
                    (exprResult.isTerminated && List.isEmpty bodyResult.ops) || bodyResult.isTerminated
            in
            { ops = exprResult.ops ++ bodyResult.ops
            , resultVar = bodyResult.resultVar
            , resultType = bodyResult.resultType
            , ctx = ctxOut, isTerminated = finalIsTerminated
            }

        Mono.MonoTailDef name params _ ->
            -- For local tail-recursive functions, we need to:
            -- 1. Add the function parameters to varMappings
            -- 2. Add the function name to varMappings (so the let body can call it)
            -- 3. Generate the function body (which contains TailCalls)
            -- 4. Generate the let body
            --
            -- Note: This is a simplified implementation. A proper implementation
            -- would generate a loop construct (scf.while) for the tail recursion.
            -- For now, we just add the function to varMappings as a closure reference.
            let
                -- Add parameters to varMappings (use ctxWithPlaceholders for mutual recursion)
                ctxWithParams =
                    List.foldl
                        (\( paramName, paramType ) acc ->
                            Ctx.addVarMapping paramName ("%" ++ paramName) (Types.monoTypeToMlir paramType) acc
                        )
                        ctxWithPlaceholders
                        params

                -- Add the function name to varMappings (as a placeholder)
                -- The function is referenced as itself - when called, it executes the body
                funcMlirType =
                    Types.ecoValue

                ctxWithFunc =
                    Ctx.addVarMapping name ("%" ++ name) funcMlirType ctxWithParams

                -- Generate the let body (which calls the function)
                bodyResult =
                    generateExpr ctxWithFunc body

                -- Restore outer siblings on exit from the let-rec group
                bodyCtx : Ctx.Context
                bodyCtx =
                    bodyResult.ctx

                ctxOut : Ctx.Context
                ctxOut =
                    { bodyCtx | currentLetSiblings = outerSiblings }
            in
            { ops = bodyResult.ops
            , resultVar = bodyResult.resultVar
            , resultType = bodyResult.resultType
            , ctx = ctxOut, isTerminated = bodyResult.isTerminated
            }



-- ====== DESTRUCT GENERATION ======


generateDestruct : Ctx.Context -> Mono.MonoDestructor -> Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateDestruct ctx (Mono.MonoDestructor name path monoType) body _ =
    let
        -- The destructor's monoType represents the type of the value at the end of the path.
        -- This is the type we should use for path generation.
        --
        -- IMPORTANT: Do NOT use destType to determine the path's target type!
        -- destType is the type of the overall body expression, not the destructed value.
        -- For example, when destructing a list element and the body returns an Int,
        -- destType would be MInt, but the destructed value is still a list (!eco.value).
        -- Using destType would incorrectly cause unboxing of lists to i64.
        --
        -- The path should produce its natural type, and the body handles any needed
        -- boxing/unboxing based on how it uses the destructed value.
        destructorMlirType =
            Types.monoTypeToMlir monoType

        -- Always use the destructor's type for path generation
        targetType =
            destructorMlirType

        ( pathOps, pathVar, ctx1 ) =
            Patterns.generateMonoPath ctx path targetType

        -- Use mapping instead of eco.construct wrapper
        ctx2 : Ctx.Context
        ctx2 =
            Ctx.addVarMapping name pathVar targetType ctx1

        bodyResult : ExprResult
        bodyResult =
            generateExpr ctx2 body
    in
    { ops = pathOps ++ bodyResult.ops
    , resultVar = bodyResult.resultVar
    , resultType = bodyResult.resultType
    , ctx = bodyResult.ctx, isTerminated = False
    }



-- ====== CASE GENERATION ======


{-| Generate shared joinpoints for case branches that are referenced multiple times.

Each (index, branchExpr) in jumps becomes an eco.joinpoint that can be jumped to
from multiple leaves in the decision tree.

-}
generateSharedJoinpoints : Ctx.Context -> List ( Int, Mono.MonoExpr ) -> MlirType -> ( Ctx.Context, List MlirOp )
generateSharedJoinpoints ctx jumps resultTy =
    List.foldl
        (\( index, branchExpr ) ( accCtx, accOps ) ->
            let
                -- Body: generate the branch expression, then eco.return
                branchRes =
                    generateExpr accCtx branchExpr

                -- Use the ACTUAL SSA type from branchRes, not Mono.typeOf
                actualTy =
                    branchRes.resultType

                -- Symmetric boxing/unboxing based on actual vs expected type
                ( coerceOps, finalVar, coerceCtx ) =
                    coerceResultToType branchRes.ctx branchRes.resultVar actualTy resultTy

                ( ctx1, retOp ) =
                    Ops.ecoReturn coerceCtx finalVar resultTy

                jpRegion =
                    Ops.mkRegion [] (branchRes.ops ++ coerceOps) retOp

                -- Continuation: a dummy region with a return (joinpoint semantics require it)
                -- Use createDummyValue to generate correct type for resultTy
                ( dummyOps, dummyVar, ctx2 ) =
                    createDummyValue ctx1 resultTy

                ( ctx3, dummyRetOp ) =
                    Ops.ecoReturn ctx2 dummyVar resultTy

                contRegion =
                    Ops.mkRegion [] dummyOps dummyRetOp

                ( ctx4, jpOp ) =
                    Ops.ecoJoinpoint ctx3 index [] jpRegion contRegion [ resultTy ]
            in
            ( ctx4, accOps ++ [ jpOp ] )
        )
        ( ctx, [] )
        jumps


{-| Generate the decision tree control flow for a case expression.
-}
generateDecider : Ctx.Context -> Name.Name -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateDecider ctx root decider resultTy =
    case decider of
        Mono.Leaf choice ->
            generateLeaf ctx root choice resultTy

        Mono.Chain testChain success failure ->
            generateChain ctx root testChain success failure resultTy

        Mono.FanOut path edges fallback ->
            generateFanOut ctx root path edges fallback resultTy


{-| Generate code for a Leaf node in the decision tree.
-}
generateLeaf : Ctx.Context -> Name.Name -> Mono.MonoChoice -> MlirType -> ExprResult
generateLeaf ctx _ choice resultTy =
    case choice of
        Mono.Inline branchExpr ->
            -- Evaluate the branch expression and return it
            let
                branchRes =
                    generateExpr ctx branchExpr
            in
            -- If the branch expression is already a terminator (e.g., nested case),
            -- we don't need to add another eco.return - just propagate it.
            if branchRes.isTerminated then
                branchRes

            else
                let
                    -- Use the ACTUAL SSA type from branchRes, not Mono.typeOf
                    actualTy =
                        branchRes.resultType

                    -- Symmetric boxing/unboxing based on actual vs expected type
                    ( coerceOps, finalVar, ctx1 ) =
                        coerceResultToType branchRes.ctx branchRes.resultVar actualTy resultTy

                    ( ctx2, retOp ) =
                        Ops.ecoReturn ctx1 finalVar resultTy
                in
                -- The return op MUST be last so mkRegionFromOps picks it as terminator
                { ops = branchRes.ops ++ coerceOps ++ [ retOp ]
                , resultVar = finalVar
                , resultType = resultTy
                , ctx = ctx2, isTerminated = False
                }

        Mono.Jump _ ->
            -- Jump to a joinpoint - generate eco.jump
            -- Use createDummyValue to generate correct type for resultTy
            let
                ( dummyOps, dummyVar, ctx1 ) =
                    createDummyValue ctx resultTy

                ( ctx2, retOp ) =
                    Ops.ecoReturn ctx1 dummyVar resultTy
            in
            { ops = dummyOps ++ [ retOp ]
            , resultVar = dummyVar
            , resultType = resultTy
            , ctx = ctx2, isTerminated = False
            }


{-| Generate code for a Chain node (test chain with success/failure branches).
-}
generateChain : Ctx.Context -> Name.Name -> List ( DT.Path, DT.Test ) -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateChain ctx root testChain success failure resultTy =
    -- Special case: If this is a direct Bool ADT pattern match (single IsBool test),
    -- pass the scrutinee directly to eco.case instead of unboxing and reboxing.
    -- This preserves the Bool ADT tags (True=1, False=0) for correct dispatch.
    case testChain of
        [ ( path, DT.IsBool True ) ] ->
            -- Direct Bool pattern match: pass the Bool ADT value to eco.case directly
            generateChainForBoolADT ctx root path success failure resultTy

        _ ->
            -- General case: compute boolean condition (i1) and box it
            generateChainGeneral ctx root testChain success failure resultTy


{-| Special handling for direct Bool ADT pattern matching.
For `case b of True -> X; False -> Y`, use eco.case with i1 scrutinee.
eco.case now accepts i1 directly (lowered to scf.if by SCF pass).
-}
generateChainForBoolADT : Ctx.Context -> Name.Name -> DT.Path -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateChainForBoolADT ctx root path success failure resultTy =
    let
        -- Get the Bool value (i1 type)
        ( pathOps, boolVar, ctx1 ) =
            Patterns.generateDTPath ctx root path I1

        -- Generate success branch (True) with eco.return
        thenRes =
            generateDecider ctx1 root success resultTy

        ( thenRegion, ctx1a ) =
            mkCaseRegionFromDecider thenRes.ctx thenRes.ops resultTy

        -- Generate failure branch (False) with eco.return
        -- Fork context: keep ctx1's variable mappings but advance nextVar to avoid SSA conflicts
        ctxForElse =
            { ctx1 | nextVar = ctx1a.nextVar }

        elseRes =
            generateDecider ctxForElse root failure resultTy

        ( elseRegion, ctx1b ) =
            mkCaseRegionFromDecider elseRes.ctx elseRes.ops resultTy

        -- eco.case on Bool: tag 1 for True (success), tag 0 for False (failure)
        ( ctx2, caseOp ) =
            Ops.ecoCase ctx1b boolVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]
    in
    { ops = pathOps ++ [ caseOp ]
    , resultVar = boolVar -- Dummy; control exits via eco.return inside regions
    , resultType = resultTy
    , ctx = ctx2, isTerminated = False
    }


{-| General case for Chain node: compute boolean condition and dispatch.
Uses eco.case with i1 scrutinee (lowered to scf.if by SCF pass).
-}
generateChainGeneral : Ctx.Context -> Name.Name -> List ( DT.Path, DT.Test ) -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateChainGeneral ctx root testChain success failure resultTy =
    let
        -- Compute the boolean condition (produces i1)
        ( condOps, condVar, ctx1 ) =
            Patterns.generateChainCondition ctx root testChain

        -- Generate success branch with eco.return
        thenRes =
            generateDecider ctx1 root success resultTy

        ( thenRegion, ctx1a ) =
            mkCaseRegionFromDecider thenRes.ctx thenRes.ops resultTy

        -- Generate failure branch with eco.return
        -- Fork context: keep ctx1's variable mappings but advance nextVar to avoid SSA conflicts
        ctxForElse =
            { ctx1 | nextVar = ctx1a.nextVar }

        elseRes =
            generateDecider ctxForElse root failure resultTy

        ( elseRegion, ctx1b ) =
            mkCaseRegionFromDecider elseRes.ctx elseRes.ops resultTy

        -- eco.case on Bool: tag 1 for True (success), tag 0 for False (failure)
        ( ctx2, caseOp ) =
            Ops.ecoCase ctx1b condVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]
    in
    { ops = condOps ++ [ caseOp ]
    , resultVar = condVar -- Dummy; control exits via eco.return inside regions
    , resultType = resultTy
    , ctx = ctx2, isTerminated = False
    }


{-| Generate code for a FanOut node (multi-way branching on constructor tags).
-}
generateFanOut : Ctx.Context -> Name.Name -> DT.Path -> List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateFanOut ctx root path edges fallback resultTy =
    -- Check if this is a Bool FanOut pattern (all edges are IsBool tests)
    if isBoolFanOut edges then
        generateBoolFanOut ctx root path edges fallback resultTy

    else
        generateFanOutGeneral ctx root path edges fallback resultTy


{-| Check if FanOut is a Bool pattern match (has IsBool True or IsBool False tests).
-}
isBoolFanOut : List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Bool
isBoolFanOut edges =
    case edges of
        [] ->
            False

        ( test, _ ) :: _ ->
            case test of
                DT.IsBool _ ->
                    True

                _ ->
                    False


{-| Handle Bool FanOut with eco.case on i1 scrutinee.
eco.case now accepts i1 directly (lowered to scf.if by SCF pass).
-}
generateBoolFanOut : Ctx.Context -> Name.Name -> DT.Path -> List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateBoolFanOut ctx root path edges fallback resultTy =
    let
        -- Get the Bool value as i1 type
        ( pathOps, boolVar, ctx1 ) =
            Patterns.generateDTPath ctx root path I1

        -- Find True and False branches
        ( trueBranch, falseBranch ) =
            findBoolBranches edges fallback

        -- Generate True branch (tag 1) with eco.return
        thenRes =
            generateDecider ctx1 root trueBranch resultTy

        ( thenRegion, ctx1a ) =
            mkCaseRegionFromDecider thenRes.ctx thenRes.ops resultTy

        -- Generate False branch (tag 0) with eco.return
        -- Fork context: keep ctx1's variable mappings but advance nextVar to avoid SSA conflicts
        ctxForElse =
            { ctx1 | nextVar = ctx1a.nextVar }

        elseRes =
            generateDecider ctxForElse root falseBranch resultTy

        ( elseRegion, ctx1b ) =
            mkCaseRegionFromDecider elseRes.ctx elseRes.ops resultTy

        -- eco.case on Bool: tag 1 for True, tag 0 for False
        -- Regions: [True region, False region] corresponding to tags [1, 0]
        ( ctx2, caseOp ) =
            Ops.ecoCase ctx1b boolVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]
    in
    { ops = pathOps ++ [ caseOp ]
    , resultVar = boolVar -- Dummy; control exits via eco.return inside regions
    , resultType = resultTy
    , ctx = ctx2, isTerminated = False
    }


{-| Find True and False branches from Bool FanOut edges.
-}
findBoolBranches : List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> ( Mono.Decider Mono.MonoChoice, Mono.Decider Mono.MonoChoice )
findBoolBranches edges fallback =
    let
        findBranch target =
            edges
                |> List.filter
                    (\( test, _ ) ->
                        case test of
                            DT.IsBool b ->
                                b == target

                            _ ->
                                False
                    )
                |> List.head
                |> Maybe.map Tuple.second
                |> Maybe.withDefault fallback
    in
    ( findBranch True, findBranch False )


{-| Extract string pattern strictly - crash if not IsStr.
This ensures we never silently drop patterns in string fanouts.
-}
extractStringPatternStrict : DT.Test -> String
extractStringPatternStrict test =
    case test of
        DT.IsStr s ->
            s

        _ ->
            crash "CGEN: expected DT.IsStr in string fanout, but got non-string test"


{-| General case FanOut using eco.case (for non-Bool ADT patterns).
eco.case accepts !eco.value scrutinee; for Bool patterns, generateBoolFanOut uses i1.
-}
generateFanOutGeneral : Ctx.Context -> Name.Name -> DT.Path -> List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateFanOutGeneral ctx root path edges fallback resultTy =
    let
        -- Collect edge tests for case kind and tag computation
        edgeTests =
            List.map Tuple.first edges

        -- Determine case kind from the first edge test
        caseKind =
            case edgeTests of
                firstTest :: _ ->
                    Patterns.caseKindFromTest firstTest

                [] ->
                    "ctor"

        -- Derive scrutinee type from case_kind:
        -- "int" -> i64, "chr" -> i16, others -> eco.value
        scrutineeType =
            Patterns.scrutineeTypeFromCaseKind caseKind

        -- Generate path to scrutinee with correct type
        -- If root is boxed but we need primitive, generateDTPath emits eco.unbox
        ( pathOps, scrutineeVar, ctx1 ) =
            Patterns.generateDTPath ctx root path scrutineeType

        -- Handle string cases specially: use positional tags and collect string patterns
        ( tags, stringPatterns ) =
            if caseKind == "str" then
                let
                    edgeCount =
                        List.length edges

                    altCount =
                        edgeCount + 1

                    -- Strictly extract string patterns - crash if any non-IsStr test
                    patterns =
                        edges
                            |> List.map Tuple.first
                            |> List.map extractStringPatternStrict

                    -- Use positional tags [0, 1, ..., N-1]
                    sequentialTags =
                        List.range 0 (altCount - 1)
                in
                ( sequentialTags, Just patterns )

            else
                let
                    edgeTags =
                        List.map (\( test, _ ) -> Patterns.testToTagInt test) edges

                    fallbackTag =
                        Patterns.computeFallbackTag edgeTests
                in
                ( edgeTags ++ [ fallbackTag ], Nothing )

        -- Generate regions for each edge
        ( edgeRegions, ctx2 ) =
            List.foldl
                (\( _, subTree ) ( accRegions, accCtx ) ->
                    let
                        subRes =
                            generateDecider accCtx root subTree resultTy

                        ( region, ctxAfterRegion ) =
                            mkCaseRegionFromDecider subRes.ctx subRes.ops resultTy
                    in
                    ( accRegions ++ [ region ], ctxAfterRegion )
                )
                ( [], ctx1 )
                edges

        -- Generate fallback region
        fallbackRes =
            generateDecider ctx2 root fallback resultTy

        ( fallbackRegion, ctx2a ) =
            mkCaseRegionFromDecider fallbackRes.ctx fallbackRes.ops resultTy

        -- Build eco.case with all regions (edges + fallback)
        allRegions =
            edgeRegions ++ [ fallbackRegion ]

        -- Build eco.case with correct scrutinee type
        -- For string cases, use ecoCaseString which includes string_patterns
        ( ctx3, caseOp ) =
            case stringPatterns of
                Just patterns ->
                    Ops.ecoCaseString ctx2a scrutineeVar scrutineeType tags patterns allRegions [ resultTy ]

                Nothing ->
                    Ops.ecoCase ctx2a scrutineeVar scrutineeType caseKind tags allRegions [ resultTy ]
    in
    -- Return the case op - no dummy construct between case and return!
    -- The lowering pattern expects: eco.case ... eco.return
    -- Use scrutineeVar as placeholder resultVar - the lowering will replace everything
    { ops = pathOps ++ [ caseOp ]
    , resultVar = scrutineeVar
    , resultType = resultTy
    , ctx = ctx3, isTerminated = False
    }


{-| Helper to build a region from a list of ops (where the last op is the terminator).
-}
mkRegionFromOps : List MlirOp -> MlirRegion
mkRegionFromOps ops =
    case List.reverse ops of
        [] ->
            -- Empty region - crash, this indicates a codegen bug
            crash "mkRegionFromOps: empty ops - region must have terminator"

        terminator :: restReversed ->
            MlirRegion
                { entry = { args = [], body = List.reverse restReversed, terminator = terminator }
                , blocks = OrderedDict.empty
                }


{-| Check if an operation is a valid region terminator.
-}
isValidTerminator : MlirOp -> Bool
isValidTerminator op =
    List.member op.name [ "eco.return", "eco.jump", "eco.crash", "eco.case" ]


{-| Create a region from decider ops. All paths must end with a valid terminator.
Crashes if invariant violated - indicates codegen bug.
-}
mkCaseRegionFromDecider : Ctx.Context -> List MlirOp -> MlirType -> ( MlirRegion, Ctx.Context )
mkCaseRegionFromDecider ctx ops resultTy =
    case List.reverse ops of
        [] ->
            crash "mkCaseRegionFromDecider: empty ops - decider must produce terminator"

        lastOp :: _ ->
            if isValidTerminator lastOp then
                ( mkRegionFromOps ops, ctx )

            else
                crash ("mkCaseRegionFromDecider: non-terminator at end: " ++ lastOp.name)


{-| Generate case expression control flow.

This is the main entry point for case expressions. It:

1.  Emits joinpoints for shared branches
2.  Generates the decision tree control flow (eco.case ops)
3.  Returns ExprResult with isTerminated=True (eco.case is a terminator)

eco.case is a control-flow exit, not a value-producing expression.
Control flow exits through eco.return ops inside the alternatives.
The EcoControlFlowToSCF pass transforms eco.case into scf.if/scf.index_switch
and inserts the final eco.return after the SCF op.

-}
generateCase : Ctx.Context -> Name.Name -> Name.Name -> Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> Mono.MonoType -> ExprResult
generateCase ctx _ root decider jumps resultMonoType =
    let
        resultMlirType =
            Types.monoTypeToMlir resultMonoType

        -- Emit joinpoints for shared branches
        ( ctx1, joinpointOps ) =
            generateSharedJoinpoints ctx jumps resultMlirType

        -- No dummy value! eco.case is a control-flow exit, not a value expression.
        -- Control leaves through eco.return inside alternatives.
        decisionResult =
            generateDecider ctx1 root decider resultMlirType
    in
    -- eco.case is a terminator - it does not produce a result value.
    -- Control flow exits through eco.return inside the decision tree regions.
    -- INVARIANT: resultVar is meaningless when isTerminated=True, must not be used.
    { ops = joinpointOps ++ decisionResult.ops
    , resultVar = "" -- INVARIANT: meaningless when isTerminated=True
    , resultType = resultMlirType
    , ctx = decisionResult.ctx
    , isTerminated = True -- eco.case is a terminator
    }



-- ====== RECORD GENERATION ======


{-| Generate MLIR code to create a record.
-}
generateRecordCreate : Ctx.Context -> List Mono.MonoExpr -> Mono.RecordLayout -> ExprResult
generateRecordCreate ctx fields layout =
    -- Register the record type for the type graph
    let
        recordType =
            Mono.MRecord layout

        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType recordType ctx
    in
    -- Empty records must use eco.constant EmptyRec (invariant: never heap-allocated)
    if layout.fieldCount == 0 then
        let
            ( resultVar, ctx1 ) =
                Ctx.freshVar ctxWithType

            ( ctx2, emptyRecOp ) =
                Ops.ecoConstantEmptyRec ctx1 resultVar
        in
        { ops = [ emptyRecOp ]
        , resultVar = resultVar
        , resultType = Types.ecoValue
        , ctx = ctx2, isTerminated = False
        }

    else
        let
            -- Use generateExprListTyped to get actual SSA types
            ( fieldsOps, fieldVarsWithTypes, ctx1 ) =
                generateExprListTyped ctxWithType fields

            -- Box fields that need to be boxed (layout says boxed, but expression is primitive)
            ( boxOps, boxedFieldVars, ctx2 ) =
                List.foldl
                    (\( ( var, ssaType ), fieldInfo ) ( opsAcc, varsAcc, ctxAcc ) ->
                        if fieldInfo.isUnboxed then
                            -- Field is stored unboxed, use as-is
                            ( opsAcc, varsAcc ++ [ var ], ctxAcc )

                        else
                            -- Field should be boxed - box using actual SSA type
                            let
                                ( moreOps, boxedVar, newCtx ) =
                                    boxToEcoValue ctxAcc var ssaType
                            in
                            ( opsAcc ++ moreOps, varsAcc ++ [ boxedVar ], newCtx )
                    )
                    ( [], [], ctx1 )
                    (List.map2 Tuple.pair fieldVarsWithTypes layout.fields)

            ( resultVar, ctx3 ) =
                Ctx.freshVar ctx2

            fieldVarPairs : List ( String, MlirType )
            fieldVarPairs =
                List.map2
                    (\v field ->
                        ( v
                        , if field.isUnboxed then
                            Types.monoTypeToMlir field.monoType

                          else
                            Types.ecoValue
                        )
                    )
                    boxedFieldVars
                    layout.fields

            -- Use eco.construct.record for records
            ( ctx4, constructOp ) =
                Ops.ecoConstructRecord ctx3 resultVar fieldVarPairs layout.fieldCount layout.unboxedBitmap
        in
        { ops = fieldsOps ++ boxOps ++ [ constructOp ]
        , resultVar = resultVar
        , resultType = Types.ecoValue
        , ctx = ctx4, isTerminated = False
        }


{-| Generate MLIR code to access a record field.
-}
generateRecordAccess : Ctx.Context -> Mono.MonoExpr -> Name.Name -> Int -> Bool -> Mono.MonoType -> ExprResult
generateRecordAccess ctx record _ index isUnboxed fieldType =
    let
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record

        ( projectVar, ctx1 ) =
            Ctx.freshVar recordResult.ctx

        -- Determine the MLIR type for the field
        fieldMlirType =
            Types.monoTypeToMlir fieldType
    in
    if isUnboxed then
        -- Field is stored unboxed - project directly to the primitive type
        let
            ( ctx2, projectOp ) =
                Ops.ecoProjectRecord ctx1 projectVar index fieldMlirType recordResult.resultVar
        in
        { ops = recordResult.ops ++ [ projectOp ]
        , resultVar = projectVar
        , resultType = fieldMlirType
        , ctx = ctx2, isTerminated = False
        }

    else if Types.isEcoValueType fieldMlirType then
        -- Field is boxed and semantic type is also !eco.value - just project
        let
            ( ctx2, projectOp ) =
                Ops.ecoProjectRecord ctx1 projectVar index Types.ecoValue recordResult.resultVar
        in
        { ops = recordResult.ops ++ [ projectOp ]
        , resultVar = projectVar
        , resultType = Types.ecoValue
        , ctx = ctx2, isTerminated = False
        }

    else
        -- Field is stored boxed but semantic type is primitive
        -- Project to get !eco.value, then unbox to primitive type
        let
            ( ctx2, projectOp ) =
                Ops.ecoProjectRecord ctx1 projectVar index Types.ecoValue recordResult.resultVar

            ( unboxOps, unboxedVar, ctx3 ) =
                Intrinsics.unboxToType ctx2 projectVar fieldMlirType
        in
        { ops = recordResult.ops ++ [ projectOp ] ++ unboxOps
        , resultVar = unboxedVar
        , resultType = fieldMlirType
        , ctx = ctx3, isTerminated = False
        }


{-| Generate MLIR code to update record fields.
-}
generateRecordUpdate : Ctx.Context -> Mono.MonoExpr -> List ( Int, Mono.MonoExpr ) -> Mono.RecordLayout -> ExprResult
generateRecordUpdate ctx record _ _ =
    let
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record

        ( resultVar, ctx1 ) =
            Ctx.freshVar recordResult.ctx

        ( ctx2, constructOp ) =
            Ops.ecoConstructRecord ctx1 resultVar [ ( recordResult.resultVar, Types.ecoValue ) ] 1 0
    in
    { ops = recordResult.ops ++ [ constructOp ]
    , resultVar = resultVar
    , resultType = Types.ecoValue
    , ctx = ctx2, isTerminated = False
    }



-- ====== TUPLE GENERATION ======


{-| Generate MLIR code to create a tuple.
-}
generateTupleCreate : Ctx.Context -> List Mono.MonoExpr -> Mono.TupleLayout -> ExprResult
generateTupleCreate ctx elements layout =
    -- Register the tuple type for the type graph
    let
        tupleType =
            Mono.MTuple layout

        ( _, ctxWithType ) =
            Ctx.getOrCreateTypeIdForMonoType tupleType ctx

        -- Use generateExprListTyped to get actual SSA types
        ( elemOps, elemVarsWithTypes, ctx1 ) =
            generateExprListTyped ctxWithType elements

        -- Box elements that need to be boxed (layout says boxed, but expression is primitive)
        ( boxOps, boxedElemVars, ctx2 ) =
            List.foldl
                (\( ( var, ssaType ), ( _, isUnboxed ) ) ( opsAcc, varsAcc, ctxAcc ) ->
                    if isUnboxed then
                        -- Element is stored unboxed, use as-is
                        ( opsAcc, varsAcc ++ [ var ], ctxAcc )

                    else
                        -- Element should be boxed - box using actual SSA type
                        let
                            ( moreOps, boxedVar, newCtx ) =
                                boxToEcoValue ctxAcc var ssaType
                        in
                        ( opsAcc ++ moreOps, varsAcc ++ [ boxedVar ], newCtx )
                )
                ( [], [], ctx1 )
                (List.map2 Tuple.pair elemVarsWithTypes layout.elements)

        ( resultVar, ctx3 ) =
            Ctx.freshVar ctx2

        elemVarPairs : List ( String, MlirType )
        elemVarPairs =
            List.map2
                (\v ( elemType, isUnboxed ) ->
                    ( v
                    , if isUnboxed then
                        Types.monoTypeToMlir elemType

                      else
                        Types.ecoValue
                    )
                )
                boxedElemVars
                layout.elements

        -- Use type-specific tuple construction ops.
        -- Now that MonoPath carries ContainerKind, projection ops match construction layout.
        ( ctx4, constructOp ) =
            case elemVarPairs of
                [ ( aVar, aType ), ( bVar, bType ) ] ->
                    -- 2-tuple: use eco.construct.tuple2
                    Ops.ecoConstructTuple2 ctx3 resultVar ( aVar, aType ) ( bVar, bType ) layout.unboxedBitmap

                [ ( aVar, aType ), ( bVar, bType ), ( cVar, cType ) ] ->
                    -- 3-tuple: use eco.construct.tuple3
                    Ops.ecoConstructTuple3 ctx3 resultVar ( aVar, aType ) ( bVar, bType ) ( cVar, cType ) layout.unboxedBitmap

                _ ->
                    -- Elm rejects tuples with >3 elements during canonicalization
                    crash "Compiler.Generate.CodeGen.MLIR" "generateTupleCreate" "unreachable: tuples >3 elements rejected by canonicalization"
    in
    { ops = elemOps ++ boxOps ++ [ constructOp ]
    , resultVar = resultVar
    , resultType = Types.ecoValue
    , ctx = ctx4, isTerminated = False
    }



-- ====== UNIT GENERATION ======


{-| Generate MLIR code for a Unit value.
-}
generateUnit : Ctx.Context -> ExprResult
generateUnit ctx =
    let
        ( var, ctx1 ) =
            Ctx.freshVar ctx

        -- Use eco.constant Unit instead of heap-allocating
        ( ctx2, unitOp ) =
            Ops.ecoConstantUnit ctx1 var
    in
    { ops = [ unitOp ]
    , resultVar = var
    , resultType = Types.ecoValue
    , ctx = ctx2, isTerminated = False
    }



-- ====== CHARACTER LITERAL DECODING ======


{-| Decode a character literal from its JS-escaped string representation.

The parser stores character literals as JS-style escape sequences (e.g., "\\u03BB" for λ).
This function decodes them back to the actual Unicode code point for MLIR codegen.

Also handles single-character strings (the actual character) for compatibility with
test code that creates AST nodes directly without going through the parser.

-}
decodeCharLiteral : String -> Int
decodeCharLiteral value =
    -- If it's a single character, just return its code directly.
    -- This handles both regular chars and the case where tests pass
    -- the actual character (e.g., a single backslash) instead of escaped form.
    if String.length value == 1 then
        case String.uncons value of
            Just ( c, _ ) ->
                Char.toCode c

            Nothing ->
                crash "decodeCharLiteral: empty character literal"

    else
        case String.uncons value of
            Just ( '\\', rest ) ->
                decodeEscape rest

            Just ( c, _ ) ->
                Char.toCode c

            Nothing ->
                crash "decodeCharLiteral: empty character literal"


decodeEscape : String -> Int
decodeEscape rest =
    case String.uncons rest of
        Just ( 'u', hex ) ->
            decodeUnicodeEscape hex

        Just ( 'n', _ ) ->
            10

        Just ( 'r', _ ) ->
            13

        Just ( 't', _ ) ->
            9

        Just ( '"', _ ) ->
            34

        Just ( '\'', _ ) ->
            39

        Just ( '\\', _ ) ->
            92

        Just ( c, _ ) ->
            crash ("decodeCharLiteral: unknown escape \\" ++ String.fromChar c)

        Nothing ->
            crash "decodeCharLiteral: trailing backslash"


decodeUnicodeEscape : String -> Int
decodeUnicodeEscape hex =
    -- Parse \uXXXX format, handle surrogate pairs
    case Hex.fromString (String.toLower (String.left 4 hex)) of
        Ok code ->
            if code >= 0xD800 && code <= 0xDBFF then
                -- High surrogate - need to decode pair
                decodeSurrogatePair code (String.dropLeft 6 hex)

            else
                code

        Err _ ->
            crash ("decodeCharLiteral: invalid hex in \\u" ++ String.left 4 hex)


decodeSurrogatePair : Int -> String -> Int
decodeSurrogatePair hi rest =
    -- rest should be "XXXX" (after "\u" has been dropped)
    case Hex.fromString (String.toLower (String.left 4 rest)) of
        Ok lo ->
            0x00010000 + ((hi - 0xD800) * 0x0400) + (lo - 0xDC00)

        Err _ ->
            crash "decodeCharLiteral: invalid low surrogate in pair"
