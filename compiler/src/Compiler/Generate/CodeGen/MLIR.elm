module Compiler.Generate.CodeGen.MLIR exposing (backend)

{-| MLIR code generation backend for the Monomorphized IR.

This backend generates MLIR from fully specialized, monomorphic code.
All polymorphism has been resolved and layout information is embedded
in the types.


# Backend

@docs backend

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.Mode as Mode
import Data.Map as EveryDict
import Data.Set as EverySet
import Dict exposing (Dict)
import Mlir.Loc as Loc exposing (Loc)
import Mlir.Mlir as Mlir
    exposing
        ( MlirAttr(..)
        , MlirModule
        , MlirOp
        , MlirRegion(..)
        , MlirType(..)
        , Visibility(..)
        )
import Mlir.Pretty as Pretty
import OrderedDict
import System.TypeCheck.IO as IO
import Utils.Crash exposing (crash)



-- BACKEND


{-| The MLIR backend that generates MLIR code from fully monomorphized IR with all polymorphism resolved.
-}
backend : CodeGen.MonoCodeGen
backend =
    { generate =
        \config ->
            generateModule config.mode config.graph |> CodeGen.TextOutput
    }



-- ECO DIALECT TYPES


{-| eco.value - boxed runtime value
-}
ecoValue : MlirType
ecoValue =
    NamedStruct "eco.value"


{-| eco.int - unboxed 64-bit signed integer
-}
ecoInt : MlirType
ecoInt =
    I64


{-| eco.float - unboxed 64-bit float
-}
ecoFloat : MlirType
ecoFloat =
    F64


{-| eco.bool - unboxed boolean (i1)
-}
ecoBool : MlirType
ecoBool =
    I1


{-| eco.char - unboxed character (i32 unicode codepoint)
-}
ecoChar : MlirType
ecoChar =
    I32



-- CONVERT MONOTYPE TO MLIR TYPE


monoTypeToMlir : Mono.MonoType -> MlirType
monoTypeToMlir monoType =
    case monoType of
        Mono.MInt ->
            ecoInt

        Mono.MFloat ->
            ecoFloat

        Mono.MBool ->
            ecoBool

        Mono.MChar ->
            ecoChar

        Mono.MString ->
            ecoValue

        Mono.MUnit ->
            ecoValue

        Mono.MList _ ->
            ecoValue

        Mono.MTuple _ ->
            ecoValue

        Mono.MRecord _ ->
            ecoValue

        Mono.MCustom _ _ _ ->
            ecoValue

        Mono.MFunction _ _ ->
            ecoValue

        Mono.MVar name constraint_ ->
            case constraint_ of
                Mono.CNumber ->
                    crash ("MLIR codegen: unresolved type variable " ++ name ++ " - should have been instantiated")

                Mono.CEcoValue ->
                    ecoValue


{-| Compute the remaining arity of a MonoType (number of function arrows).
For MFunction a b, this counts how many nested function arrows there are.
-}
functionArity : Mono.MonoType -> Int
functionArity monoType =
    case monoType of
        Mono.MFunction _ result ->
            1 + functionArity result

        _ ->
            0


{-| Count total arity - the total number of arguments across all curried levels.
For MFunction [a, b] (MFunction [c] d), this returns 3.
-}
countTotalArity : Mono.MonoType -> Int
countTotalArity monoType =
    case monoType of
        Mono.MFunction argTypes result ->
            List.length argTypes + countTotalArity result

        _ ->
            0



-- CONTEXT


{-| Function signature for invariant checking: param types and return type
-}
type alias FuncSignature =
    { paramTypes : List Mono.MonoType
    , returnType : Mono.MonoType
    }


type alias Context =
    { nextVar : Int
    , nextOpId : Int
    , mode : Mode.Mode
    , registry : Mono.SpecializationRegistry
    , pendingLambdas : List PendingLambda
    , signatures : Dict Int FuncSignature -- SpecId -> signature for invariant checking
    }


type alias PendingLambda =
    { name : String
    , captures : List ( Name.Name, Mono.MonoType )
    , params : List ( Name.Name, Mono.MonoType )
    , body : Mono.MonoExpr
    }


initContext : Mode.Mode -> Mono.SpecializationRegistry -> Dict Int FuncSignature -> Context
initContext mode registry signatures =
    { nextVar = 0
    , nextOpId = 0
    , mode = mode
    , registry = registry
    , pendingLambdas = []
    , signatures = signatures
    }


freshVar : Context -> ( String, Context )
freshVar ctx =
    ( "%" ++ String.fromInt ctx.nextVar
    , { ctx | nextVar = ctx.nextVar + 1 }
    )


freshOpId : Context -> ( String, Context )
freshOpId ctx =
    ( "op" ++ String.fromInt ctx.nextOpId
    , { ctx | nextOpId = ctx.nextOpId + 1 }
    )



-- SIGNATURE EXTRACTION (for invariant checking)


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
            Just
                { paramTypes = List.map Tuple.second params
                , returnType = monoType
                }

        Mono.MonoCtor ctorLayout monoType ->
            -- Constructor - params are the fields
            Just
                { paramTypes = List.map .monoType ctorLayout.fields
                , returnType = monoType
                }

        Mono.MonoEnum _ monoType ->
            -- Nullary enum constructor
            Just
                { paramTypes = []
                , returnType = monoType
                }

        Mono.MonoExtern monoType ->
            -- External - treat as nullary for now
            Just
                { paramTypes = []
                , returnType = monoType
                }

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
buildSignatures : EveryDict.Dict Int Int Mono.MonoNode -> Dict Int FuncSignature
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



-- EXPRESSION RESULT


type alias ExprResult =
    { ops : List MlirOp
    , resultVar : String
    , ctx : Context
    }


emptyResult : Context -> String -> ExprResult
emptyResult ctx var =
    { ops = [], resultVar = var, ctx = ctx }



-- INTRINSIC DEFINITIONS
-- (Same as your original; omitted detailed comments for brevity.)


type Intrinsic
    = UnaryInt { op : String }
    | BinaryInt { op : String }
    | UnaryFloat { op : String }
    | BinaryFloat { op : String }
    | IntToFloat
    | FloatToInt { op : String }
    | IntComparison { op : String }
    | FloatComparison { op : String }
    | FloatClassify { op : String }
    | ConstantFloat { value : Float }


kernelIntrinsic : Name.Name -> Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
kernelIntrinsic home name argTypes resultType =
    case home of
        "Basics" ->
            basicsIntrinsic name argTypes resultType

        "Bitwise" ->
            bitwiseIntrinsic name argTypes resultType

        _ ->
            Nothing


basicsIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
basicsIntrinsic name argTypes resultType =
    case ( name, argTypes, resultType ) of
        ( "pi", [], Mono.MFloat ) ->
            Just (ConstantFloat { value = 3.141592653589793 })

        ( "e", [], Mono.MFloat ) ->
            Just (ConstantFloat { value = 2.718281828459045 })

        ( "add", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.add" })

        ( "sub", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.sub" })

        ( "mul", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.mul" })

        ( "idiv", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.div" })

        ( "modBy", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.modby" })

        ( "remainderBy", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.remainderby" })

        ( "negate", [ Mono.MInt ], Mono.MInt ) ->
            Just (UnaryInt { op = "eco.int.negate" })

        ( "abs", [ Mono.MInt ], Mono.MInt ) ->
            Just (UnaryInt { op = "eco.int.abs" })

        ( "pow", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.pow" })

        ( "add", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.add" })

        ( "sub", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.sub" })

        ( "mul", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.mul" })

        ( "fdiv", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.div" })

        ( "negate", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.negate" })

        ( "abs", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.abs" })

        ( "pow", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.pow" })

        ( "sqrt", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.sqrt" })

        ( "sin", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.sin" })

        ( "cos", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.cos" })

        ( "tan", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.tan" })

        ( "asin", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.asin" })

        ( "acos", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.acos" })

        ( "atan", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.atan" })

        ( "atan2", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.atan2" })

        ( "logBase", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Nothing

        ( "log", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.log" })

        ( "isNaN", [ Mono.MFloat ], Mono.MBool ) ->
            Just (FloatClassify { op = "eco.float.isNaN" })

        ( "isInfinite", [ Mono.MFloat ], Mono.MBool ) ->
            Just (FloatClassify { op = "eco.float.isInfinite" })

        ( "toFloat", [ Mono.MInt ], Mono.MFloat ) ->
            Just IntToFloat

        ( "round", [ Mono.MFloat ], Mono.MInt ) ->
            Just (FloatToInt { op = "eco.float.round" })

        ( "floor", [ Mono.MFloat ], Mono.MInt ) ->
            Just (FloatToInt { op = "eco.float.floor" })

        ( "ceiling", [ Mono.MFloat ], Mono.MInt ) ->
            Just (FloatToInt { op = "eco.float.ceiling" })

        ( "truncate", [ Mono.MFloat ], Mono.MInt ) ->
            Just (FloatToInt { op = "eco.float.truncate" })

        ( "min", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.min" })

        ( "max", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.max" })

        ( "min", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.min" })

        ( "max", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.max" })

        ( "lt", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntComparison { op = "eco.int.lt" })

        ( "le", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntComparison { op = "eco.int.le" })

        ( "gt", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntComparison { op = "eco.int.gt" })

        ( "ge", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntComparison { op = "eco.int.ge" })

        ( "eq", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntComparison { op = "eco.int.eq" })

        ( "neq", [ Mono.MInt, Mono.MInt ], Mono.MBool ) ->
            Just (IntComparison { op = "eco.int.ne" })

        ( "lt", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatComparison { op = "eco.float.lt" })

        ( "le", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatComparison { op = "eco.float.le" })

        ( "gt", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatComparison { op = "eco.float.gt" })

        ( "ge", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatComparison { op = "eco.float.ge" })

        ( "eq", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatComparison { op = "eco.float.eq" })

        ( "neq", [ Mono.MFloat, Mono.MFloat ], Mono.MBool ) ->
            Just (FloatComparison { op = "eco.float.ne" })

        _ ->
            Nothing


bitwiseIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
bitwiseIntrinsic name argTypes resultType =
    case ( name, argTypes, resultType ) of
        ( "and", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.and" })

        ( "or", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.or" })

        ( "xor", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.xor" })

        ( "complement", [ Mono.MInt ], Mono.MInt ) ->
            Just (UnaryInt { op = "eco.int.complement" })

        ( "shiftLeftBy", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.shl" })

        ( "shiftRightBy", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.shr" })

        ( "shiftRightZfBy", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.shru" })

        _ ->
            Nothing


generateIntrinsicOp : Context -> Intrinsic -> String -> List String -> ( Context, MlirOp )
generateIntrinsicOp ctx intrinsic resultVar argVars =
    case intrinsic of
        UnaryInt { op } ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            ecoUnaryOp ctx op resultVar ( operand, I64 ) I64

        BinaryInt { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    ecoBinaryOp ctx op resultVar ( lhs, I64 ) ( rhs, I64 ) I64

                _ ->
                    ecoUnaryOp ctx op resultVar ( "%error", I64 ) I64

        UnaryFloat { op } ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            ecoUnaryOp ctx op resultVar ( operand, F64 ) F64

        BinaryFloat { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    ecoBinaryOp ctx op resultVar ( lhs, F64 ) ( rhs, F64 ) F64

                _ ->
                    ecoUnaryOp ctx op resultVar ( "%error", F64 ) F64

        IntToFloat ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            ecoUnaryOp ctx "eco.int.toFloat" resultVar ( operand, I64 ) F64

        FloatToInt { op } ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            ecoUnaryOp ctx op resultVar ( operand, F64 ) I64

        IntComparison { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    ecoBinaryOp ctx op resultVar ( lhs, I64 ) ( rhs, I64 ) I1

                _ ->
                    ecoBinaryOp ctx op resultVar ( "%error", I64 ) ( "%error", I64 ) I1

        FloatComparison { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    ecoBinaryOp ctx op resultVar ( lhs, F64 ) ( rhs, F64 ) I1

                _ ->
                    ecoBinaryOp ctx op resultVar ( "%error", F64 ) ( "%error", F64 ) I1

        FloatClassify { op } ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            ecoUnaryOp ctx op resultVar ( operand, F64 ) I1

        ConstantFloat { value } ->
            arithConstantFloat ctx resultVar value



-- OP BUILDER (already defined above)
-- GENERATE MODULE


generateModule : Mode.Mode -> Mono.MonoGraph -> String
generateModule mode (Mono.MonoGraph { nodes, main, registry }) =
    let
        signatures : Dict Int FuncSignature
        signatures =
            buildSignatures nodes

        ctx : Context
        ctx =
            initContext mode registry signatures

        ( ops, ctxAfterNodes ) =
            EveryDict.foldl compare
                (\specId node ( accOps, accCtx ) ->
                    let
                        ( op, newCtx ) =
                            generateNode accCtx specId node
                    in
                    ( accOps ++ [ op ], newCtx )
                )
                ( [], ctx )
                nodes

        ( lambdaOps, finalCtx ) =
            processLambdas ctxAfterNodes

        mainOps : List MlirOp
        mainOps =
            case main of
                Just mainInfo ->
                    generateMainEntry finalCtx mainInfo

                Nothing ->
                    []

        mlirModule : MlirModule
        mlirModule =
            { body = lambdaOps ++ ops ++ mainOps
            , loc = Loc.unknown
            }

        _ =
            if not (verifyCodegenInvariants mlirModule finalCtx) then
                crash "MLIR codegen: invariant violation"

            else
                ()
    in
    Pretty.ppModule mlirModule



-- LAMBDA PROCESSING (unchanged)


processLambdas : Context -> ( List MlirOp, Context )
processLambdas ctx =
    case ctx.pendingLambdas of
        [] ->
            ( [], ctx )

        lambdas ->
            let
                ctxCleared =
                    { ctx | pendingLambdas = [] }

                ( lambdaOps, ctxAfter ) =
                    List.foldl
                        (\lambda ( accOps, accCtx ) ->
                            let
                                ( op, newCtx ) =
                                    generateLambdaFunc accCtx lambda
                            in
                            ( accOps ++ [ op ], newCtx )
                        )
                        ( [], ctxCleared )
                        lambdas

                ( moreOps, finalCtx ) =
                    processLambdas ctxAfter
            in
            ( lambdaOps ++ moreOps, finalCtx )


generateLambdaFunc : Context -> PendingLambda -> ( MlirOp, Context )
generateLambdaFunc ctx lambda =
    let
        captureArgPairs : List ( String, MlirType )
        captureArgPairs =
            List.map (\( name, _ ) -> ( "%" ++ name, ecoValue )) lambda.captures

        paramArgPairs : List ( String, MlirType )
        paramArgPairs =
            List.map (\( name, ty ) -> ( "%" ++ name, monoTypeToMlir ty )) lambda.params

        allArgPairs : List ( String, MlirType )
        allArgPairs =
            captureArgPairs ++ paramArgPairs

        ctxWithArgs : Context
        ctxWithArgs =
            { ctx | nextVar = List.length allArgPairs }

        exprResult : ExprResult
        exprResult =
            generateExpr ctxWithArgs lambda.body

        returnType : MlirType
        returnType =
            monoTypeToMlir (Mono.typeOf lambda.body)

        ( ctx1, returnOp ) =
            ecoReturn exprResult.ctx exprResult.resultVar returnType

        region : MlirRegion
        region =
            mkRegion allArgPairs exprResult.ops returnOp

        ( ctx2, funcOp ) =
            funcFunc ctx1 lambda.name allArgPairs returnType region
    in
    ( funcOp, ctx2 )



-- GENERATE MAIN ENTRY


generateMainEntry : Context -> Mono.MainInfo -> List MlirOp
generateMainEntry ctx mainInfo =
    case mainInfo of
        Mono.StaticMain mainSpecId ->
            let
                ( callVar, ctx1 ) =
                    freshVar ctx

                mainFuncName : String
                mainFuncName =
                    specIdToFuncName ctx.registry mainSpecId

                ( ctx2, callOp ) =
                    ecoCallNamed ctx1 callVar mainFuncName [] ecoValue

                ( ctx3, returnOp ) =
                    ecoReturn ctx2 callVar ecoValue

                region : MlirRegion
                region =
                    mkRegion [] [ callOp ] returnOp

                ( _, mainOp ) =
                    funcFunc ctx3 "main" [] ecoValue region
            in
            [ mainOp ]



-- GENERATE NODE


generateNode : Context -> Mono.SpecId -> Mono.MonoNode -> ( MlirOp, Context )
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
                ( ctx1, op ) =
                    generateEnum ctx funcName tag monoType
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
            canonicalToMLIRName home ++ "_" ++ sanitizeName name ++ "_$_" ++ String.fromInt specId

        Nothing ->
            "unknown_$_" ++ String.fromInt specId



-- GENERATE DEFINE


generateDefine : Context -> String -> Mono.MonoExpr -> Mono.MonoType -> ( MlirOp, Context )
generateDefine ctx funcName expr monoType =
    case expr of
        Mono.MonoClosure closureInfo body _ ->
            generateClosureFunc ctx funcName closureInfo body monoType

        _ ->
            -- Value (thunk) - wrap in nullary function
            let
                exprResult : ExprResult
                exprResult =
                    generateExpr ctx expr

                retTy =
                    monoTypeToMlir monoType

                ( ctx1, returnOp ) =
                    ecoReturn exprResult.ctx exprResult.resultVar retTy

                region : MlirRegion
                region =
                    mkRegion [] exprResult.ops returnOp

                ( ctx2, funcOp ) =
                    funcFunc ctx1 funcName [] retTy region
            in
            ( funcOp, ctx2 )


generateClosureFunc : Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ( MlirOp, Context )
generateClosureFunc ctx funcName closureInfo body _ =
    let
        argPairs : List ( String, MlirType )
        argPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, monoTypeToMlir ty ))
                closureInfo.params

        ctxWithArgs : Context
        ctxWithArgs =
            { ctx | nextVar = List.length closureInfo.params }

        exprResult : ExprResult
        exprResult =
            generateExpr ctxWithArgs body

        returnType : MlirType
        returnType =
            monoTypeToMlir (Mono.typeOf body)

        ( ctx1, returnOp ) =
            ecoReturn exprResult.ctx exprResult.resultVar returnType

        region : MlirRegion
        region =
            mkRegion argPairs exprResult.ops returnOp

        ( ctx2, funcOp ) =
            funcFunc ctx1 funcName argPairs returnType region
    in
    ( funcOp, ctx2 )



-- GENERATE TAIL FUNC


generateTailFunc : Context -> String -> List ( Name.Name, Mono.MonoType ) -> Mono.MonoExpr -> Mono.MonoType -> ( MlirOp, Context )
generateTailFunc ctx funcName params expr monoType =
    let
        argPairs : List ( String, MlirType )
        argPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, monoTypeToMlir ty ))
                params

        ctxWithArgs : Context
        ctxWithArgs =
            { ctx | nextVar = List.length params }

        exprResult : ExprResult
        exprResult =
            generateExpr ctxWithArgs expr

        retTy =
            monoTypeToMlir monoType

        ( ctx1, returnOp ) =
            ecoReturn exprResult.ctx exprResult.resultVar retTy

        region : MlirRegion
        region =
            mkRegion argPairs exprResult.ops returnOp

        ( ctx2, funcOp ) =
            funcFunc ctx1 funcName argPairs retTy region
    in
    ( funcOp, ctx2 )



-- GENERATE CTOR


generateCtor : Context -> String -> Mono.CtorLayout -> Mono.MonoType -> ( Context, MlirOp )
generateCtor ctx funcName ctorLayout _ =
    let
        arity : Int
        arity =
            List.length ctorLayout.fields
    in
    if arity == 0 then
        -- Nullary constructor
        let
            ( resultVar, ctx1 ) =
                freshVar ctx

            ( ctx2, constructOp ) =
                ecoConstruct ctx1 resultVar ctorLayout.tag 0 0 []

            ( ctx3, returnOp ) =
                ecoReturn ctx2 resultVar ecoValue

            region : MlirRegion
            region =
                mkRegion [] [ constructOp ] returnOp
        in
        funcFunc ctx3 funcName [] ecoValue region

    else
        -- Constructor with arguments
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
                            monoTypeToMlir field.monoType

                        else
                            ecoValue
                    )
                    ctorLayout.fields

            argPairs : List ( String, MlirType )
            argPairs =
                List.map2 Tuple.pair argNames argTypes

            ( resultVar, ctx1 ) =
                freshVar { ctx | nextVar = arity }

            ( ctx2, constructOp ) =
                ecoConstruct ctx1 resultVar ctorLayout.tag arity ctorLayout.unboxedBitmap argPairs

            ( ctx3, returnOp ) =
                ecoReturn ctx2 resultVar ecoValue

            region : MlirRegion
            region =
                mkRegion argPairs [ constructOp ] returnOp
        in
        funcFunc ctx3 funcName argPairs ecoValue region



-- GENERATE ENUM


generateEnum : Context -> String -> Int -> Mono.MonoType -> ( Context, MlirOp )
generateEnum ctx funcName tag _ =
    let
        ( resultVar, ctx1 ) =
            freshVar ctx

        ( ctx2, constructOp ) =
            ecoConstruct ctx1 resultVar tag 0 0 []

        ( ctx3, returnOp ) =
            ecoReturn ctx2 resultVar ecoValue

        region : MlirRegion
        region =
            mkRegion [] [ constructOp ] returnOp
    in
    funcFunc ctx3 funcName [] ecoValue region



-- GENERATE EXTERN


generateExtern : Context -> String -> Mono.MonoType -> ( Context, MlirOp )
generateExtern ctx funcName monoType =
    -- Generate an extern declaration with a placeholder body.
    -- MLIR's func.func requires at least one region, so we create a stub body
    -- that constructs a Unit value and returns it. The actual implementation
    -- will be provided by the runtime linker.
    let
        returnType =
            monoTypeToMlir monoType

        ( stubVar, ctx1 ) =
            freshVar ctx

        -- Create a placeholder Unit value
        ( ctx2, constructOp ) =
            mlirOp ctx1 "eco.construct"
                |> opBuilder.withResults [ ( stubVar, ecoValue ) ]
                |> opBuilder.withAttrs
                    (Dict.fromList
                        [ ( "_operand_types", ArrayAttr [] )
                        , ( "size", IntAttr 0 )
                        , ( "tag", IntAttr 0 )
                        , ( "unboxed_bitmap", IntAttr 0 )
                        ]
                    )
                |> opBuilder.build

        ( ctx3, returnOp ) =
            ecoReturn ctx2 stubVar ecoValue

        region : MlirRegion
        region =
            mkRegion [] [ constructOp ] returnOp

        attrs =
            Dict.fromList
                [ ( "sym_name", StringAttr funcName )
                , ( "sym_visibility", VisibilityAttr Private )
                , ( "function_type"
                  , TypeAttr
                        (FunctionType
                            { inputs = []
                            , results = [ returnType ]
                            }
                        )
                  )
                ]
    in
    mlirOp ctx3 "func.func"
        |> opBuilder.withRegions [ region ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build



-- GENERATE CYCLE


generateCycle : Context -> String -> List ( Name.Name, Mono.MonoExpr ) -> Mono.MonoType -> ( MlirOp, Context )
generateCycle ctx funcName definitions monoType =
    -- Generate mutually recursive definitions
    -- For now, generate a thunk that creates a record of all the cycle definitions
    let
        ( defOps, defVars, finalCtx ) =
            List.foldl
                (\( _, expr ) ( accOps, accVars, accCtx ) ->
                    let
                        result : ExprResult
                        result =
                            generateExpr accCtx expr
                    in
                    ( accOps ++ result.ops, accVars ++ [ result.resultVar ], result.ctx )
                )
                ( [], [], ctx )
                definitions

        ( resultVar, ctx1 ) =
            freshVar finalCtx

        arity : Int
        arity =
            List.length definitions

        defVarPairs : List ( String, MlirType )
        defVarPairs =
            List.map (\v -> ( v, ecoValue )) defVars

        ( ctx2, cycleOp ) =
            ecoConstruct ctx1 resultVar 0 arity 0 defVarPairs

        ( ctx3, returnOp ) =
            ecoReturn ctx2 resultVar ecoValue

        region : MlirRegion
        region =
            mkRegion [] (defOps ++ [ cycleOp ]) returnOp

        ( ctx4, funcOp ) =
            funcFunc ctx3 funcName [] (monoTypeToMlir monoType) region
    in
    ( funcOp, ctx4 )



-- GENERATE EXPRESSION


generateExpr : Context -> Mono.MonoExpr -> ExprResult
generateExpr ctx expr =
    case expr of
        Mono.MonoLiteral lit _ ->
            generateLiteral ctx lit

        Mono.MonoVarLocal name _ ->
            emptyResult ctx ("%" ++ name)

        Mono.MonoVarGlobal _ specId monoType ->
            generateVarGlobal ctx specId monoType

        Mono.MonoVarKernel _ home name monoType ->
            generateVarKernel ctx home name monoType

        Mono.MonoList _ items _ ->
            generateList ctx items

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

        Mono.MonoDestruct destructor body _ ->
            generateDestruct ctx destructor body

        Mono.MonoCase scrutinee1 scrutinee2 decider jumps _ ->
            generateCase ctx scrutinee1 scrutinee2 decider jumps

        Mono.MonoRecordCreate fields layout _ ->
            generateRecordCreate ctx fields layout

        Mono.MonoRecordAccess record fieldName index isUnboxed _ ->
            generateRecordAccess ctx record fieldName index isUnboxed

        Mono.MonoRecordUpdate record updates layout _ ->
            generateRecordUpdate ctx record updates layout

        Mono.MonoTupleCreate _ elements layout _ ->
            generateTupleCreate ctx elements layout

        Mono.MonoUnit ->
            generateUnit ctx

        Mono.MonoAccessor _ fieldName _ ->
            generateAccessor ctx fieldName



-- LITERAL GENERATION


generateLiteral : Context -> Mono.Literal -> ExprResult
generateLiteral ctx lit =
    case lit of
        Mono.LBool value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( ctx2, op ) =
                    arithConstantBool ctx1 var value
            in
            { ops = [ op ]
            , resultVar = var
            , ctx = ctx2
            }

        Mono.LInt value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( ctx2, op ) =
                    arithConstantInt ctx1 var value
            in
            { ops = [ op ]
            , resultVar = var
            , ctx = ctx2
            }

        Mono.LFloat value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( ctx2, op ) =
                    arithConstantFloat ctx1 var value
            in
            { ops = [ op ]
            , resultVar = var
            , ctx = ctx2
            }

        Mono.LChar value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                codepoint : Int
                codepoint =
                    String.uncons value
                        |> Maybe.map (Tuple.first >> Char.toCode)
                        |> Maybe.withDefault 0

                ( ctx2, op ) =
                    arithConstantChar ctx1 var codepoint
            in
            { ops = [ op ]
            , resultVar = var
            , ctx = ctx2
            }

        Mono.LStr value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( ctx2, op ) =
                    ecoStringLiteral ctx1 var value
            in
            { ops = [ op ]
            , resultVar = var
            , ctx = ctx2
            }



-- VARIABLE GENERATION


generateVarGlobal : Context -> Mono.SpecId -> Mono.MonoType -> ExprResult
generateVarGlobal ctx specId monoType =
    let
        ( var, ctx1 ) =
            freshVar ctx

        funcName : String
        funcName =
            specIdToFuncName ctx.registry specId
    in
    case monoType of
        Mono.MFunction _ _ ->
            let
                arity : Int
                arity =
                    countTotalArity monoType
            in
            if arity == 0 then
                -- Zero-arity function (thunk): call directly instead of creating a PAP.
                -- papCreate requires arity > 0 (num_captured < arity invariant).
                let
                    ( ctx2, callOp ) =
                        ecoCallNamed ctx1 var funcName [] (monoTypeToMlir monoType)
                in
                { ops = [ callOp ]
                , resultVar = var
                , ctx = ctx2
                }

            else
                -- Function-typed global with arity > 0: create a closure (papCreate) with no captures
                let
                    attrs =
                        Dict.fromList
                            [ ( "function", SymbolRefAttr funcName )
                            , ( "arity", IntAttr arity )
                            , ( "num_captured", IntAttr 0 )
                            ]

                    ( ctx2, papOp ) =
                        mlirOp ctx1 "eco.papCreate"
                            |> opBuilder.withResults [ ( var, ecoValue ) ]
                            |> opBuilder.withAttrs attrs
                            |> opBuilder.build
                in
                { ops = [ papOp ]
                , resultVar = var
                , ctx = ctx2
                }

        _ ->
            -- Non-function type: call the function directly (e.g., zero-arg constructors)
            let
                ( ctx2, callOp ) =
                    ecoCallNamed ctx1 var funcName [] (monoTypeToMlir monoType)
            in
            { ops = [ callOp ]
            , resultVar = var
            , ctx = ctx2
            }


generateVarKernel : Context -> Name.Name -> Name.Name -> Mono.MonoType -> ExprResult
generateVarKernel ctx home name monoType =
    let
        ( var, ctx1 ) =
            freshVar ctx
    in
    -- Check for intrinsic constants (pi, e)
    case kernelIntrinsic home name [] monoType of
        Just (ConstantFloat { value }) ->
            let
                ( ctx2, floatOp ) =
                    arithConstantFloat ctx1 var value
            in
            { ops = [ floatOp ]
            , resultVar = var
            , ctx = ctx2
            }

        Just _ ->
            let
                kernelName : String
                kernelName =
                    "Elm_Kernel_" ++ home ++ "_" ++ name

                ( ctx2, callOp ) =
                    ecoCallNamed ctx1 var kernelName [] (monoTypeToMlir monoType)
            in
            { ops = [ callOp ]
            , resultVar = var
            , ctx = ctx2
            }

        Nothing ->
            let
                kernelName : String
                kernelName =
                    "Elm_Kernel_" ++ home ++ "_" ++ name

                ( ctx2, callOp ) =
                    ecoCallNamed ctx1 var kernelName [] (monoTypeToMlir monoType)
            in
            { ops = [ callOp ]
            , resultVar = var
            , ctx = ctx2
            }



-- LIST GENERATION


generateList : Context -> List Mono.MonoExpr -> ExprResult
generateList ctx items =
    case items of
        [] ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( ctx2, constructOp ) =
                    ecoConstruct ctx1 var 0 0 0 []
            in
            { ops = [ constructOp ]
            , resultVar = var
            , ctx = ctx2
            }

        _ ->
            let
                ( nilVar, ctx1 ) =
                    freshVar ctx

                ( ctx2, nilOp ) =
                    ecoConstruct ctx1 nilVar 0 0 0 []

                ( consOps, finalVar, finalCtx ) =
                    List.foldr
                        (\item ( accOps, tailVar, accCtx ) ->
                            let
                                result : ExprResult
                                result =
                                    generateExpr accCtx item

                                ( consVar, ctx3 ) =
                                    freshVar result.ctx

                                ( ctx4, consOp ) =
                                    ecoConstruct ctx3 consVar 1 2 0 [ ( result.resultVar, ecoValue ), ( tailVar, ecoValue ) ]
                            in
                            ( accOps ++ result.ops ++ [ consOp ], consVar, ctx4 )
                        )
                        ( [], nilVar, ctx2 )
                        items
            in
            { ops = nilOp :: consOps
            , resultVar = finalVar
            , ctx = finalCtx
            }



-- CLOSURE GENERATION


generateClosure : Context -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateClosure ctx closureInfo body monoType =
    let
        ( captureOps, captureVars, ctx1 ) =
            List.foldl
                (\( _, expr, _ ) ( accOps, accVars, accCtx ) ->
                    let
                        result : ExprResult
                        result =
                            generateExpr accCtx expr
                    in
                    ( accOps ++ result.ops, accVars ++ [ result.resultVar ], result.ctx )
                )
                ( [], [], ctx )
                closureInfo.captures

        captureVarsWithTypes : List ( String, Mono.MonoType )
        captureVarsWithTypes =
            List.map2
                (\( _, expr, _ ) var -> ( var, Mono.typeOf expr ))
                closureInfo.captures
                captureVars

        ( boxOps, boxedCaptureVars, ctx1b ) =
            boxArgsIfNeeded ctx1 captureVarsWithTypes

        ( resultVar, ctx2 ) =
            freshVar ctx1b

        numCaptured : Int
        numCaptured =
            List.length closureInfo.captures

        arity : Int
        arity =
            numCaptured + List.length closureInfo.params

        captureTypes : List ( Name.Name, Mono.MonoType )
        captureTypes =
            List.map (\( name, expr, _ ) -> ( name, Mono.typeOf expr )) closureInfo.captures

        pendingLambda : PendingLambda
        pendingLambda =
            { name = lambdaIdToString closureInfo.lambdaId
            , captures = captureTypes
            , params = closureInfo.params
            , body = body
            }
    in
    if arity == 0 then
        -- Zero-arity closure (thunk with no captures): call the lambda directly.
        -- papCreate requires arity > 0 (num_captured < arity invariant).
        let
            ctx3 : Context
            ctx3 =
                { ctx2 | pendingLambdas = pendingLambda :: ctx2.pendingLambdas }

            ( ctx4, callOp ) =
                ecoCallNamed ctx3 resultVar (lambdaIdToString closureInfo.lambdaId) [] (monoTypeToMlir monoType)
        in
        { ops = captureOps ++ boxOps ++ [ callOp ]
        , resultVar = resultVar
        , ctx = ctx4
        }

    else
        -- Non-zero arity: create a PAP with captures
        let
            captureVarNames : List String
            captureVarNames =
                boxedCaptureVars

            operandTypesAttr =
                if List.isEmpty captureVarNames then
                    Dict.empty

                else
                    Dict.singleton "_operand_types"
                        (ArrayAttr (List.map (\_ -> TypeAttr ecoValue) captureVarNames))

            papAttrs =
                Dict.union operandTypesAttr
                    (Dict.fromList
                        [ ( "function", SymbolRefAttr (lambdaIdToString closureInfo.lambdaId) )
                        , ( "arity", IntAttr arity )
                        , ( "num_captured", IntAttr numCaptured )
                        ]
                    )

            ( ctx3, papOp ) =
                mlirOp ctx2 "eco.papCreate"
                    |> opBuilder.withOperands captureVarNames
                    |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
                    |> opBuilder.withAttrs papAttrs
                    |> opBuilder.build

            ctx4 : Context
            ctx4 =
                { ctx3 | pendingLambdas = pendingLambda :: ctx3.pendingLambdas }
        in
        { ops = captureOps ++ boxOps ++ [ papOp ]
        , resultVar = resultVar
        , ctx = ctx4
        }


lambdaIdToString : Mono.LambdaId -> String
lambdaIdToString lambdaId =
    case lambdaId of
        Mono.AnonymousLambda home uid ->
            canonicalToMLIRName home ++ "_lambda_" ++ String.fromInt uid



-- CALL GENERATION


isEcoValueType : MlirType -> Bool
isEcoValueType ty =
    case ty of
        NamedStruct "eco.value" ->
            True

        _ ->
            False


argVarPairsFromExprs : List Mono.MonoExpr -> List String -> List ( String, MlirType )
argVarPairsFromExprs argExprs argVars =
    List.map2
        (\expr var -> ( var, monoTypeToMlir (Mono.typeOf expr) ))
        argExprs
        argVars


boxIfNeeded : Context -> String -> Mono.MonoType -> ( List MlirOp, String, Context )
boxIfNeeded ctx var monoTy =
    let
        mlirTy =
            monoTypeToMlir monoTy
    in
    if isEcoValueType mlirTy then
        ( [], var, ctx )

    else
        let
            ( boxedVar, ctx1 ) =
                freshVar ctx

            attrs =
                Dict.singleton "_operand_types" (ArrayAttr [ TypeAttr mlirTy ])

            ( ctx2, boxOp ) =
                mlirOp ctx1 "eco.box"
                    |> opBuilder.withOperands [ var ]
                    |> opBuilder.withResults [ ( boxedVar, ecoValue ) ]
                    |> opBuilder.withAttrs attrs
                    |> opBuilder.build
        in
        ( [ boxOp ], boxedVar, ctx2 )


boxArgsIfNeeded :
    Context
    -> List ( String, Mono.MonoType )
    -> ( List MlirOp, List String, Context )
boxArgsIfNeeded ctx args =
    List.foldl
        (\( var, ty ) ( opsAcc, varsAcc, ctxAcc ) ->
            let
                ( moreOps, boxedVar, ctx1 ) =
                    boxIfNeeded ctxAcc var ty
            in
            ( opsAcc ++ moreOps, varsAcc ++ [ boxedVar ], ctx1 )
        )
        ( [], [], ctx )
        args


generateCall : Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateCall ctx func args resultType =
    case func of
        Mono.MonoVarGlobal _ specId _ ->
            let
                ( argOps, argVars, ctx1 ) =
                    generateExprList ctx args

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                argVarPairs : List ( String, MlirType )
                argVarPairs =
                    argVarPairsFromExprs args argVars

                funcName : String
                funcName =
                    specIdToFuncName ctx.registry specId

                ( ctx3, callOp ) =
                    ecoCallNamed ctx2 resultVar funcName argVarPairs (monoTypeToMlir resultType)
            in
            { ops = argOps ++ [ callOp ]
            , resultVar = resultVar
            , ctx = ctx3
            }

        Mono.MonoVarKernel _ home name _ ->
            let
                ( argOps, argVars, ctx1 ) =
                    generateExprList ctx args

                argTypes : List Mono.MonoType
                argTypes =
                    List.map Mono.typeOf args
            in
            case ( home, name, argVars ) of
                ( "Basics", "logBase", [ baseVar, xVar ] ) ->
                    let
                        ( logXVar, ctx2 ) =
                            freshVar ctx1

                        ( logBaseVar, ctx3 ) =
                            freshVar ctx2

                        ( resVar, ctx4 ) =
                            freshVar ctx3

                        ( ctx5, logXOp ) =
                            ecoUnaryOp ctx2 "eco.float.log" logXVar ( xVar, F64 ) F64

                        ( ctx6, logBaseOp ) =
                            ecoUnaryOp ctx5 "eco.float.log" logBaseVar ( baseVar, F64 ) F64

                        ( ctx7, divOp ) =
                            ecoBinaryOp ctx6 "eco.float.div" resVar ( logXVar, F64 ) ( logBaseVar, F64 ) F64
                    in
                    { ops = argOps ++ [ logXOp, logBaseOp, divOp ]
                    , resultVar = resVar
                    , ctx = ctx7
                    }

                _ ->
                    case kernelIntrinsic home name argTypes resultType of
                        Just intrinsic ->
                            let
                                ( resVar, ctx2 ) =
                                    freshVar ctx1

                                ( ctx3, intrinsicOp ) =
                                    generateIntrinsicOp ctx2 intrinsic resVar argVars
                            in
                            { ops = argOps ++ [ intrinsicOp ]
                            , resultVar = resVar
                            , ctx = ctx3
                            }

                        Nothing ->
                            let
                                argsWithTypes : List ( String, Mono.MonoType )
                                argsWithTypes =
                                    List.map2 (\expr var -> ( var, Mono.typeOf expr )) args argVars

                                ( boxOps, boxedVars, ctx1b ) =
                                    boxArgsIfNeeded ctx1 argsWithTypes

                                ( resVar, ctx2 ) =
                                    freshVar ctx1b

                                argVarPairs : List ( String, MlirType )
                                argVarPairs =
                                    List.map (\v -> ( v, ecoValue )) boxedVars

                                kernelName : String
                                kernelName =
                                    "Elm_Kernel_" ++ home ++ "_" ++ name

                                ( ctx3, callOp ) =
                                    ecoCallNamed ctx2 resVar kernelName argVarPairs (monoTypeToMlir resultType)
                            in
                            { ops = argOps ++ boxOps ++ [ callOp ]
                            , resultVar = resVar
                            , ctx = ctx3
                            }

        Mono.MonoVarLocal name _ ->
            let
                ( argOps, argVars, ctx1 ) =
                    generateExprList ctx args

                argsWithTypes : List ( String, Mono.MonoType )
                argsWithTypes =
                    List.map2 (\expr var -> ( var, Mono.typeOf expr )) args argVars

                ( boxOps, boxedVars, ctx1b ) =
                    boxArgsIfNeeded ctx1 argsWithTypes

                ( resVar, ctx2 ) =
                    freshVar ctx1b

                allOperandNames : List String
                allOperandNames =
                    ("%" ++ name) :: boxedVars

                allOperandTypes : List MlirType
                allOperandTypes =
                    List.map (\_ -> ecoValue) allOperandNames

                remainingArity : Int
                remainingArity =
                    functionArity resultType

                papExtendAttrs =
                    Dict.fromList
                        [ ( "_operand_types", ArrayAttr (List.map TypeAttr allOperandTypes) )
                        , ( "remaining_arity", IntAttr remainingArity )
                        ]

                ( ctx3, papExtendOp ) =
                    mlirOp ctx2 "eco.papExtend"
                        |> opBuilder.withOperands allOperandNames
                        |> opBuilder.withResults [ ( resVar, monoTypeToMlir resultType ) ]
                        |> opBuilder.withAttrs papExtendAttrs
                        |> opBuilder.build
            in
            { ops = argOps ++ boxOps ++ [ papExtendOp ]
            , resultVar = resVar
            , ctx = ctx3
            }

        _ ->
            let
                funcResult : ExprResult
                funcResult =
                    generateExpr ctx func

                ( argOps, argVars, ctx1 ) =
                    generateExprList funcResult.ctx args

                argsWithTypes : List ( String, Mono.MonoType )
                argsWithTypes =
                    List.map2 (\expr var -> ( var, Mono.typeOf expr )) args argVars

                ( boxOps, boxedVars, ctx1b ) =
                    boxArgsIfNeeded ctx1 argsWithTypes

                ( resVar, ctx2 ) =
                    freshVar ctx1b

                allOperandNames : List String
                allOperandNames =
                    funcResult.resultVar :: boxedVars

                allOperandTypes : List MlirType
                allOperandTypes =
                    List.map (\_ -> ecoValue) allOperandNames

                remainingArity : Int
                remainingArity =
                    functionArity resultType

                papExtendAttrs =
                    Dict.fromList
                        [ ( "_operand_types", ArrayAttr (List.map TypeAttr allOperandTypes) )
                        , ( "remaining_arity", IntAttr remainingArity )
                        ]

                ( ctx3, papExtendOp ) =
                    mlirOp ctx2 "eco.papExtend"
                        |> opBuilder.withOperands allOperandNames
                        |> opBuilder.withResults [ ( resVar, monoTypeToMlir resultType ) ]
                        |> opBuilder.withAttrs papExtendAttrs
                        |> opBuilder.build
            in
            { ops = funcResult.ops ++ argOps ++ boxOps ++ [ papExtendOp ]
            , resultVar = resVar
            , ctx = ctx3
            }


generateExprList : Context -> List Mono.MonoExpr -> ( List MlirOp, List String, Context )
generateExprList ctx exprs =
    List.foldl
        (\expr ( accOps, accVars, accCtx ) ->
            let
                result : ExprResult
                result =
                    generateExpr accCtx expr
            in
            ( accOps ++ result.ops, accVars ++ [ result.resultVar ], result.ctx )
        )
        ( [], [], ctx )
        exprs



-- TAIL CALL GENERATION


generateTailCall : Context -> Name.Name -> List ( Name.Name, Mono.MonoExpr ) -> ExprResult
generateTailCall ctx name args =
    let
        ( argsOps, argVars, ctx1 ) =
            List.foldl
                (\( _, expr ) ( accOps, accVars, accCtx ) ->
                    let
                        result : ExprResult
                        result =
                            generateExpr accCtx expr
                    in
                    ( accOps ++ result.ops, accVars ++ [ result.resultVar ], result.ctx )
                )
                ( [], [], ctx )
                args

        argVarNames : List String
        argVarNames =
            argVars

        argVarTypes : List MlirType
        argVarTypes =
            List.map (\( _, expr ) -> monoTypeToMlir (Mono.typeOf expr)) args

        jumpAttrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr (List.map TypeAttr argVarTypes) )
                , ( "target", StringAttr name )
                ]

        ( ctx2, jumpOp ) =
            mlirOp ctx1 "eco.jump"
                |> opBuilder.withOperands argVarNames
                |> opBuilder.withAttrs jumpAttrs
                |> opBuilder.isTerminator True
                |> opBuilder.build

        ( resultVar, ctx3 ) =
            freshVar ctx2

        ( ctx4, constructOp ) =
            ecoConstruct ctx3 resultVar 0 0 0 []
    in
    { ops = argsOps ++ [ jumpOp, constructOp ]
    , resultVar = resultVar
    , ctx = ctx4
    }



-- IF GENERATION (still a stub: evaluates branches sequentially)


generateIf : Context -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> Mono.MonoExpr -> ExprResult
generateIf ctx branches final =
    case branches of
        [] ->
            generateExpr ctx final

        ( _, thenBranch ) :: restBranches ->
            let
                thenResult : ExprResult
                thenResult =
                    generateExpr ctx thenBranch

                elseResult : ExprResult
                elseResult =
                    generateIf thenResult.ctx restBranches final
            in
            { ops = thenResult.ops ++ elseResult.ops
            , resultVar = elseResult.resultVar
            , ctx = elseResult.ctx
            }



-- LET GENERATION (kept as in original; you may refine later)


generateLet : Context -> Mono.MonoDef -> Mono.MonoExpr -> ExprResult
generateLet ctx def body =
    case def of
        Mono.MonoDef name expr ->
            let
                exprResult : ExprResult
                exprResult =
                    generateExpr ctx expr

                ( ctx1, aliasOp ) =
                    ecoConstruct exprResult.ctx ("%" ++ name) 0 1 0 [ ( exprResult.resultVar, ecoValue ) ]

                bodyResult : ExprResult
                bodyResult =
                    generateExpr ctx1 body
            in
            { ops = exprResult.ops ++ [ aliasOp ] ++ bodyResult.ops
            , resultVar = bodyResult.resultVar
            , ctx = bodyResult.ctx
            }

        Mono.MonoTailDef _ _ ->
            generateExpr ctx body



-- DESTRUCT GENERATION (kept as in original)


generateDestruct : Context -> Mono.MonoDestructor -> Mono.MonoExpr -> ExprResult
generateDestruct ctx (Mono.MonoDestructor name path) body =
    let
        ( pathOps, pathVar, ctx1 ) =
            generateMonoPath ctx path

        ( ctx2, aliasOp ) =
            ecoConstruct ctx1 ("%" ++ name) 0 1 0 [ ( pathVar, ecoValue ) ]

        bodyResult : ExprResult
        bodyResult =
            generateExpr ctx2 body
    in
    { ops = pathOps ++ [ aliasOp ] ++ bodyResult.ops
    , resultVar = bodyResult.resultVar
    , ctx = bodyResult.ctx
    }


generateMonoPath : Context -> Mono.MonoPath -> ( List MlirOp, String, Context )
generateMonoPath ctx path =
    case path of
        Mono.MonoRoot name ->
            ( [], "%" ++ name, ctx )

        Mono.MonoIndex index subPath ->
            let
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, projectOp ) =
                    ecoProject ctx2 resultVar index False subVar ecoValue
            in
            ( subOps ++ [ projectOp ]
            , resultVar
            , ctx3
            )

        Mono.MonoField index subPath ->
            let
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, projectOp ) =
                    ecoProject ctx2 resultVar index False subVar ecoValue
            in
            ( subOps ++ [ projectOp ]
            , resultVar
            , ctx3
            )

        Mono.MonoUnbox subPath ->
            generateMonoPath ctx subPath



-- CASE GENERATION (stub)


generateCase : Context -> Name.Name -> Name.Name -> Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> ExprResult
generateCase ctx _ _ _ _ =
    let
        ( resultVar, ctx1 ) =
            freshVar ctx

        ( ctx2, constructOp ) =
            ecoConstruct ctx1 resultVar 0 0 0 []
    in
    { ops = [ constructOp ]
    , resultVar = resultVar
    , ctx = ctx2
    }



-- RECORD GENERATION


generateRecordCreate : Context -> List Mono.MonoExpr -> Mono.RecordLayout -> ExprResult
generateRecordCreate ctx fields layout =
    let
        ( fieldsOps, fieldVars, ctx1 ) =
            generateExprList ctx fields

        ( resultVar, ctx2 ) =
            freshVar ctx1

        fieldVarPairs : List ( String, MlirType )
        fieldVarPairs =
            List.map2
                (\v field ->
                    ( v
                    , if field.isUnboxed then
                        monoTypeToMlir field.monoType

                      else
                        ecoValue
                    )
                )
                fieldVars
                layout.fields

        ( ctx3, constructOp ) =
            ecoConstruct ctx2 resultVar 0 layout.fieldCount layout.unboxedBitmap fieldVarPairs
    in
    { ops = fieldsOps ++ [ constructOp ]
    , resultVar = resultVar
    , ctx = ctx3
    }


generateRecordAccess : Context -> Mono.MonoExpr -> Name.Name -> Int -> Bool -> ExprResult
generateRecordAccess ctx record _ index isUnboxed =
    let
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record

        ( resultVar, ctx1 ) =
            freshVar recordResult.ctx

        ( ctx2, projectOp ) =
            ecoProject ctx1 resultVar index isUnboxed recordResult.resultVar ecoValue
    in
    { ops = recordResult.ops ++ [ projectOp ]
    , resultVar = resultVar
    , ctx = ctx2
    }


generateRecordUpdate : Context -> Mono.MonoExpr -> List ( Int, Mono.MonoExpr ) -> Mono.RecordLayout -> ExprResult
generateRecordUpdate ctx record _ _ =
    let
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record

        ( resultVar, ctx1 ) =
            freshVar recordResult.ctx

        ( ctx2, constructOp ) =
            ecoConstruct ctx1 resultVar 0 1 0 [ ( recordResult.resultVar, ecoValue ) ]
    in
    { ops = recordResult.ops ++ [ constructOp ]
    , resultVar = resultVar
    , ctx = ctx2
    }



-- TUPLE GENERATION


generateTupleCreate : Context -> List Mono.MonoExpr -> Mono.TupleLayout -> ExprResult
generateTupleCreate ctx elements layout =
    let
        ( elemOps, elemVars, ctx1 ) =
            generateExprList ctx elements

        ( resultVar, ctx2 ) =
            freshVar ctx1

        elemVarPairs : List ( String, MlirType )
        elemVarPairs =
            List.map2
                (\v ( elemType, isUnboxed ) ->
                    ( v
                    , if isUnboxed then
                        monoTypeToMlir elemType

                      else
                        ecoValue
                    )
                )
                elemVars
                layout.elements

        ( ctx3, constructOp ) =
            ecoConstruct ctx2 resultVar 0 layout.arity layout.unboxedBitmap elemVarPairs
    in
    { ops = elemOps ++ [ constructOp ]
    , resultVar = resultVar
    , ctx = ctx3
    }



-- UNIT GENERATION


generateUnit : Context -> ExprResult
generateUnit ctx =
    let
        ( var, ctx1 ) =
            freshVar ctx

        ( ctx2, constructOp ) =
            ecoConstruct ctx1 var 0 0 0 []
    in
    { ops = [ constructOp ]
    , resultVar = var
    , ctx = ctx2
    }



-- ACCESSOR GENERATION


generateAccessor : Context -> Name.Name -> ExprResult
generateAccessor ctx fieldName =
    let
        ( var, ctx1 ) =
            freshVar ctx

        attrs =
            Dict.fromList
                [ ( "function", SymbolRefAttr ("accessor_" ++ fieldName) )
                , ( "arity", IntAttr 1 )
                , ( "num_captured", IntAttr 0 )
                ]

        ( ctx2, papOp ) =
            mlirOp ctx1 "eco.papCreate"
                |> opBuilder.withResults [ ( var, ecoValue ) ]
                |> opBuilder.withAttrs attrs
                |> opBuilder.build
    in
    { ops = [ papOp ]
    , resultVar = var
    , ctx = ctx2
    }



-- INVARIANT CHECKS


verifyCodegenInvariants : MlirModule -> Context -> Bool
verifyCodegenInvariants mlirModule ctx =
    let
        definedFuncs =
            mlirModule.body
                |> List.foldl
                    (\op acc ->
                        if op.name == "func.func" then
                            case Dict.get "sym_name" op.attrs of
                                Just (StringAttr symName) ->
                                    EverySet.insert identity symName acc

                                _ ->
                                    acc

                        else
                            acc
                    )
                    EverySet.empty

        allOps =
            collectAllOps mlirModule.body

        callsAreKnown =
            List.all
                (\op ->
                    if op.name == "eco.call" then
                        case Dict.get "callee" op.attrs of
                            Just (SymbolRefAttr callee) ->
                                EverySet.member identity callee definedFuncs || isLikelyExternal callee

                            _ ->
                                False

                    else
                        True
                )
                allOps

        cfgWellFormed =
            List.all blocksWellFormed (collectFuncRegions mlirModule.body)
    in
    callsAreKnown && cfgWellFormed


collectAllOps : List MlirOp -> List MlirOp
collectAllOps topLevelOps =
    let
        step op acc =
            let
                nestedOps =
                    op.regions
                        |> List.concatMap
                            (\(MlirRegion region) ->
                                let
                                    entryOps =
                                        region.entry.body

                                    blockOps =
                                        OrderedDict.values region.blocks
                                            |> List.concatMap (\b -> b.body)
                                in
                                entryOps ++ blockOps
                            )
            in
            op :: List.foldl step acc nestedOps
    in
    List.foldr step [] topLevelOps


collectFuncRegions : List MlirOp -> List MlirRegion
collectFuncRegions ops =
    ops
        |> List.filter (\op -> op.name == "func.func")
        |> List.concatMap .regions


blocksWellFormed : MlirRegion -> Bool
blocksWellFormed (MlirRegion region) =
    let
        checkBlock ops =
            let
                step op ( seenTerm, ok ) =
                    if not ok then
                        ( seenTerm, False )

                    else if seenTerm then
                        ( seenTerm, False )

                    else if op.isTerminator then
                        ( True, True )

                    else
                        ( False, True )

                ( _, check ) =
                    List.foldl step ( False, True ) ops
            in
            check

        entryOk =
            checkBlock region.entry.body

        otherOk =
            OrderedDict.values region.blocks
                |> List.all (\b -> checkBlock b.body)
    in
    entryOk && otherOk


isLikelyExternal : String -> Bool
isLikelyExternal name =
    String.startsWith "Elm_Kernel_" name
        || String.startsWith "accessor_" name
        || name
        == "main"



-- HELPERS


canonicalToMLIRName : IO.Canonical -> String
canonicalToMLIRName (IO.Canonical _ moduleName) =
    moduleName
        |> String.replace "." "_"


sanitizeName : String -> String
sanitizeName name =
    name
        |> String.replace "+" "_plus_"
        |> String.replace "-" "_minus_"
        |> String.replace "*" "_star_"
        |> String.replace "/" "_slash_"
        |> String.replace "<" "_lt_"
        |> String.replace ">" "_gt_"
        |> String.replace "=" "_eq_"
        |> String.replace "&" "_amp_"
        |> String.replace "|" "_pipe_"
        |> String.replace "!" "_bang_"
        |> String.replace "?" "_question_"
        |> String.replace ":" "_colon_"
        |> String.replace "." "_dot_"
        |> String.replace "$" "_dollar_"



-- ECO DIALECT OP HELPERS


opBuilder : Mlir.OpBuilderFns e
opBuilder =
    Mlir.opBuilder


mlirOp : Context -> String -> Mlir.OpBuilder Context
mlirOp env =
    Mlir.mlirOp (\e -> freshOpId e |> (\( id, ctx ) -> ( ctx, id ))) env


{-| eco.construct - create a heap object
-}
ecoConstruct : Context -> String -> Int -> Int -> Int -> List ( String, MlirType ) -> ( Context, MlirOp )
ecoConstruct ctx resultVar tag size unboxedBitmap operands =
    let
        operandNames =
            List.map Tuple.first operands

        operandTypesAttr =
            if List.isEmpty operands then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr (List.map (\( _, t ) -> TypeAttr t) operands))

        attrs =
            Dict.union operandTypesAttr
                (Dict.fromList
                    [ ( "tag", IntAttr tag )
                    , ( "size", IntAttr size )
                    , ( "unboxed_bitmap", IntAttr unboxedBitmap )
                    ]
                )
    in
    mlirOp ctx "eco.construct"
        |> opBuilder.withOperands operandNames
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.call - call a function by name
-}
ecoCallNamed : Context -> String -> String -> List ( String, MlirType ) -> MlirType -> ( Context, MlirOp )
ecoCallNamed ctx resultVar funcName operands returnType =
    let
        operandNames =
            List.map Tuple.first operands

        operandTypesAttr =
            if List.isEmpty operands then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr (List.map (\( _, t ) -> TypeAttr t) operands))

        attrs =
            Dict.union operandTypesAttr
                (Dict.singleton "callee" (SymbolRefAttr funcName))
    in
    mlirOp ctx "eco.call"
        |> opBuilder.withOperands operandNames
        |> opBuilder.withResults [ ( resultVar, returnType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.project - extract a field from a record/custom/tuple
-}
ecoProject : Context -> String -> Int -> Bool -> String -> MlirType -> ( Context, MlirOp )
ecoProject ctx resultVar index isUnboxed operand operandType =
    let
        resultType =
            if isUnboxed then
                I64

            else
                ecoValue

        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr [ TypeAttr operandType ] )
                , ( "index", IntAttr index )
                , ( "unboxed", BoolAttr isUnboxed )
                ]
    in
    mlirOp ctx "eco.project"
        |> opBuilder.withOperands [ operand ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.return - return a value
-}
ecoReturn : Context -> String -> MlirType -> ( Context, MlirOp )
ecoReturn ctx operand operandType =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr [ TypeAttr operandType ])
    in
    mlirOp ctx "eco.return"
        |> opBuilder.withOperands [ operand ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.isTerminator True
        |> opBuilder.build


{-| eco.string\_literal - create a string constant
-}
ecoStringLiteral : Context -> String -> String -> ( Context, MlirOp )
ecoStringLiteral ctx resultVar value =
    mlirOp ctx "eco.string_literal"
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (StringAttr value))
        |> opBuilder.build


{-| arith.constant for integers
-}
arithConstantInt : Context -> String -> Int -> ( Context, MlirOp )
arithConstantInt ctx resultVar value =
    mlirOp ctx "arith.constant"
        |> opBuilder.withResults [ ( resultVar, I64 ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (TypedIntAttr value I64))
        |> opBuilder.build


{-| arith.constant for floats
-}
arithConstantFloat : Context -> String -> Float -> ( Context, MlirOp )
arithConstantFloat ctx resultVar value =
    let
        -- For whole numbers, use TypedIntAttr to produce "5 : f64" which is valid MLIR.
        -- FloatAttr uses String.fromFloat which omits the decimal point for whole numbers,
        -- producing invalid MLIR like "5" instead of "5.0" for f64 type.
        valueAttr =
            if value == toFloat (round value) then
                TypedIntAttr (round value) F64

            else
                FloatAttr value
    in
    mlirOp ctx "arith.constant"
        |> opBuilder.withResults [ ( resultVar, F64 ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" valueAttr)
        |> opBuilder.build


{-| arith.constant for booleans
-}
arithConstantBool : Context -> String -> Bool -> ( Context, MlirOp )
arithConstantBool ctx resultVar value =
    mlirOp ctx "arith.constant"
        |> opBuilder.withResults [ ( resultVar, I1 ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (BoolAttr value))
        |> opBuilder.build


{-| arith.constant for characters
-}
arithConstantChar : Context -> String -> Int -> ( Context, MlirOp )
arithConstantChar ctx resultVar codepoint =
    mlirOp ctx "arith.constant"
        |> opBuilder.withResults [ ( resultVar, I32 ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (TypedIntAttr codepoint I32))
        |> opBuilder.build


{-| Build a unary eco op (e.g., eco.int.negate, eco.float.sqrt)
-}
ecoUnaryOp : Context -> String -> String -> ( String, MlirType ) -> MlirType -> ( Context, MlirOp )
ecoUnaryOp ctx opName resultVar ( operand, operandTy ) resultTy =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr [ TypeAttr operandTy ])
    in
    mlirOp ctx opName
        |> opBuilder.withOperands [ operand ]
        |> opBuilder.withResults [ ( resultVar, resultTy ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Build a binary eco op (e.g., eco.int.add, eco.float.mul)
-}
ecoBinaryOp : Context -> String -> String -> ( String, MlirType ) -> ( String, MlirType ) -> MlirType -> ( Context, MlirOp )
ecoBinaryOp ctx opName resultVar ( lhs, lhsTy ) ( rhs, rhsTy ) resultTy =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr [ TypeAttr lhsTy, TypeAttr rhsTy ])
    in
    mlirOp ctx opName
        |> opBuilder.withOperands [ lhs, rhs ]
        |> opBuilder.withResults [ ( resultVar, resultTy ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Create a region with a single entry block
-}
mkRegion : List ( String, MlirType ) -> List MlirOp -> MlirOp -> MlirRegion
mkRegion args body terminator =
    MlirRegion
        { entry =
            { args = args
            , body = body
            , terminator = terminator
            }
        , blocks = OrderedDict.empty
        }


{-| func.func - define a function
-}
funcFunc : Context -> String -> List ( String, MlirType ) -> MlirType -> MlirRegion -> ( Context, MlirOp )
funcFunc ctx funcName args returnType bodyRegion =
    let
        attrs =
            Dict.fromList
                [ ( "sym_name", StringAttr funcName )
                , ( "sym_visibility", VisibilityAttr Private )
                , ( "function_type"
                  , TypeAttr
                        (FunctionType
                            { inputs = List.map Tuple.second args
                            , results = [ returnType ]
                            }
                        )
                  )
                ]
    in
    mlirOp ctx "func.func"
        |> opBuilder.withRegions [ bodyRegion ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build
