module Compiler.Generate.CodeGen.MLIR exposing (backend)

{-| MLIR code generation backend for the Monomorphized IR.

This backend generates MLIR from fully specialized, monomorphic code.
All polymorphism has been resolved and layout information is embedded
in the types.


# Backend

@docs backend

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.Package as Pkg
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.Mode as Mode
import Compiler.Optimize.Erased.DecisionTree as DT
import Data.Map as EveryDict
import Dict exposing (Dict)
import Mlir.Loc as Loc
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


{-| eco.char - unboxed character (i16 unicode codepoint, BMP only)
-}
ecoChar : MlirType
ecoChar =
    I16



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
                    I64

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


{-| Decompose a function type into its flattened argument types and final return type.
For MFunction [a, b] (MFunction [c] d), this returns ([a, b, c], d).
For non-function types, returns ([], type).
-}
decomposeFunctionType : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
decomposeFunctionType monoType =
    case monoType of
        Mono.MFunction argTypes result ->
            let
                ( nestedArgs, finalResult ) =
                    decomposeFunctionType result
            in
            ( argTypes ++ nestedArgs, finalResult )

        other ->
            ( [], other )



-- CONTEXT


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
            decomposeFunctionType funcType
    in
    { paramTypes = argTypes
    , returnType = retType
    }


{-| Check if a kernel function is polymorphic and needs all-boxed ABI.
These functions accept any type and must receive boxed !eco.value arguments.
-}
isPolymorphicKernel : String -> String -> Bool
isPolymorphicKernel home name =
    case home of
        "Debug" ->
            -- All Debug module functions are polymorphic
            True

        "Json" ->
            -- Json.Decode.succeed, Json.Encode.null, etc.
            name == "succeed" || name == "null"

        "Platform" ->
            -- Platform.Cmd.none, Platform.Sub.none
            name == "none"

        _ ->
            False


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


type alias Context =
    { nextVar : Int
    , nextOpId : Int
    , mode : Mode.Mode
    , registry : Mono.SpecializationRegistry
    , pendingLambdas : List PendingLambda
    , signatures : Dict Int FuncSignature -- SpecId -> signature for invariant checking
    , varMappings : Dict String String -- Let-bound name -> SSA variable name
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
    , varMappings = Dict.empty
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


{-| Look up a variable name, checking varMappings first for let-bound aliases.
This allows let bindings to directly reference the SSA variable from the expression
rather than going through an eco.construct wrapper.
-}
lookupVar : Context -> String -> String
lookupVar ctx name =
    case Dict.get name ctx.varMappings of
        Just ssaVar ->
            ssaVar

        Nothing ->
            "%" ++ name


{-| Add a variable mapping from a let-bound name to its SSA variable.
-}
addVarMapping : String -> String -> Context -> Context
addVarMapping name ssaVar ctx =
    { ctx | varMappings = Dict.insert name ssaVar ctx.varMappings }



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
    | UnaryBool { op : String }
    | BinaryBool { op : String }
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
    -- Note: We match primarily on argument types because the result type from
    -- the MonoCall might be a type variable (MVar) when the call is used in a
    -- polymorphic context (e.g., `Debug.log "x" (negate 5)` where the result type
    -- inherits from Debug.log's `a` parameter). For functions where the return type
    -- is the same as the argument type, we use wildcard matching on resultType.
    case ( name, argTypes ) of
        ( "pi", [] ) ->
            if resultType == Mono.MFloat || isTypeVar resultType then
                Just (ConstantFloat { value = 3.141592653589793 })

            else
                Nothing

        ( "e", [] ) ->
            if resultType == Mono.MFloat || isTypeVar resultType then
                Just (ConstantFloat { value = 2.718281828459045 })

            else
                Nothing

        ( "add", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.add" })

        ( "sub", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.sub" })

        ( "mul", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.mul" })

        ( "idiv", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.div" })

        ( "modBy", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.modby" })

        ( "remainderBy", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.remainderby" })

        ( "negate", [ Mono.MInt ] ) ->
            Just (UnaryInt { op = "eco.int.negate" })

        ( "abs", [ Mono.MInt ] ) ->
            Just (UnaryInt { op = "eco.int.abs" })

        ( "pow", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.pow" })

        ( "add", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.add" })

        ( "sub", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.sub" })

        ( "mul", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.mul" })

        ( "fdiv", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.div" })

        ( "negate", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.negate" })

        ( "abs", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.abs" })

        ( "pow", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.pow" })

        ( "sqrt", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.sqrt" })

        ( "sin", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.sin" })

        ( "cos", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.cos" })

        ( "tan", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.tan" })

        ( "asin", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.asin" })

        ( "acos", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.acos" })

        ( "atan", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.atan" })

        ( "atan2", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.atan2" })

        ( "logBase", [ Mono.MFloat, Mono.MFloat ] ) ->
            Nothing

        ( "log", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.log" })

        ( "isNaN", [ Mono.MFloat ] ) ->
            Just (FloatClassify { op = "eco.float.isNaN" })

        ( "isInfinite", [ Mono.MFloat ] ) ->
            Just (FloatClassify { op = "eco.float.isInfinite" })

        ( "toFloat", [ Mono.MInt ] ) ->
            Just IntToFloat

        ( "round", [ Mono.MFloat ] ) ->
            Just (FloatToInt { op = "eco.float.round" })

        ( "floor", [ Mono.MFloat ] ) ->
            Just (FloatToInt { op = "eco.float.floor" })

        ( "ceiling", [ Mono.MFloat ] ) ->
            Just (FloatToInt { op = "eco.float.ceiling" })

        ( "truncate", [ Mono.MFloat ] ) ->
            Just (FloatToInt { op = "eco.float.truncate" })

        ( "min", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.min" })

        ( "max", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.max" })

        ( "min", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.min" })

        ( "max", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.max" })

        ( "lt", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.lt" })

        ( "le", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.le" })

        ( "gt", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.gt" })

        ( "ge", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.ge" })

        ( "eq", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.eq" })

        ( "neq", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.ne" })

        ( "lt", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.lt" })

        ( "le", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.le" })

        ( "gt", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.gt" })

        ( "ge", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.ge" })

        ( "eq", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.eq" })

        ( "neq", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.ne" })

        -- Boolean operations
        ( "not", [ Mono.MBool ] ) ->
            Just (UnaryBool { op = "eco.bool.not" })

        ( "and", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BinaryBool { op = "eco.bool.and" })

        ( "or", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BinaryBool { op = "eco.bool.or" })

        ( "xor", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BinaryBool { op = "eco.bool.xor" })

        _ ->
            Nothing


bitwiseIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
bitwiseIntrinsic name argTypes _ =
    case ( name, argTypes ) of
        ( "and", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.and" })

        ( "or", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.or" })

        ( "xor", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.xor" })

        ( "complement", [ Mono.MInt ] ) ->
            Just (UnaryInt { op = "eco.int.complement" })

        ( "shiftLeftBy", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.shl" })

        ( "shiftRightBy", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.shr" })

        ( "shiftRightZfBy", [ Mono.MInt, Mono.MInt ] ) ->
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

        UnaryBool { op } ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            ecoUnaryOp ctx op resultVar ( operand, I1 ) I1

        BinaryBool { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    ecoBinaryOp ctx op resultVar ( lhs, I1 ) ( rhs, I1 ) I1

                _ ->
                    ecoUnaryOp ctx op resultVar ( "%error", I1 ) I1

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
    -- that returns a default value of the correct type. The actual implementation
    -- will be provided by the runtime linker.
    let
        -- Decompose function type to get argument types and return type
        ( argMonoTypes, resultMonoType ) =
            decomposeFunctionType monoType

        -- Convert to MLIR types
        argMlirTypes : List MlirType
        argMlirTypes =
            List.map monoTypeToMlir argMonoTypes

        resultMlirType : MlirType
        resultMlirType =
            monoTypeToMlir resultMonoType

        -- Create block argument pairs (arg0, arg1, etc.)
        argPairs : List ( String, MlirType )
        argPairs =
            List.indexedMap (\i ty -> ( "%arg" ++ String.fromInt i, ty )) argMlirTypes

        -- Start fresh var counter after block args
        ctxWithArgs : Context
        ctxWithArgs =
            { ctx | nextVar = List.length argPairs }

        -- Create a stub return value of the correct type
        ( stubVar, ctx1 ) =
            freshVar ctxWithArgs

        ( ctx2, stubOp ) =
            generateStubValue ctx1 stubVar resultMonoType resultMlirType

        ( ctx3, returnOp ) =
            ecoReturn ctx2 stubVar resultMlirType

        region : MlirRegion
        region =
            mkRegion argPairs [ stubOp ] returnOp

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
    mlirOp ctx3 "func.func"
        |> opBuilder.withRegions [ region ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| Generate a stub value of the given type for extern function bodies.
-}
generateStubValue : Context -> String -> Mono.MonoType -> MlirType -> ( Context, MlirOp )
generateStubValue ctx resultVar monoType mlirType =
    case monoType of
        Mono.MInt ->
            arithConstantInt ctx resultVar 0

        Mono.MFloat ->
            arithConstantFloat ctx resultVar 0.0

        Mono.MBool ->
            arithConstantBool ctx resultVar False

        Mono.MChar ->
            arithConstantChar ctx resultVar 0

        _ ->
            -- For all other types (String, List, Record, Custom, Function, etc.),
            -- return a boxed Unit value
            mlirOp ctx "eco.construct"
                |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
                |> opBuilder.withAttrs
                    (Dict.fromList
                        [ ( "_operand_types", ArrayAttr Nothing [] )
                        , ( "size", IntAttr Nothing 0 )
                        , ( "tag", IntAttr Nothing 0 )
                        , ( "unboxed_bitmap", IntAttr Nothing 0 )
                        ]
                    )
                |> opBuilder.build



-- GENERATE CYCLE


generateCycle : Context -> String -> List ( Name.Name, Mono.MonoExpr ) -> Mono.MonoType -> ( MlirOp, Context )
generateCycle ctx funcName definitions monoType =
    -- Generate mutually recursive definitions
    -- For now, generate a thunk that creates a record of all the cycle definitions
    let
        -- Generate expressions and collect results with their types
        ( defOps, defVarsWithTypes, finalCtx ) =
            List.foldl
                (\( _, expr ) ( accOps, accVars, accCtx ) ->
                    let
                        result : ExprResult
                        result =
                            generateExpr accCtx expr

                        exprType =
                            Mono.typeOf expr
                    in
                    ( accOps ++ result.ops, accVars ++ [ ( result.resultVar, exprType ) ], result.ctx )
                )
                ( [], [], ctx )
                definitions

        -- Box any primitive values before storing in the cycle
        ( boxOps, boxedVars, ctxAfterBox ) =
            boxArgsIfNeeded finalCtx defVarsWithTypes

        ( resultVar, ctx1 ) =
            freshVar ctxAfterBox

        arity : Int
        arity =
            List.length definitions

        defVarPairs : List ( String, MlirType )
        defVarPairs =
            List.map (\v -> ( v, ecoValue )) boxedVars

        ( ctx2, cycleOp ) =
            ecoConstruct ctx1 resultVar 0 arity 0 defVarPairs

        ( ctx3, returnOp ) =
            ecoReturn ctx2 resultVar ecoValue

        region : MlirRegion
        region =
            mkRegion [] (defOps ++ boxOps ++ [ cycleOp ]) returnOp

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
            emptyResult ctx (lookupVar ctx name)

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
                            , ( "arity", IntAttr Nothing arity )
                            , ( "num_captured", IntAttr Nothing 0 )
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

                                -- Box primitive elements before storing in the list
                                elemType =
                                    Mono.typeOf item

                                ( boxOps, boxedVar, ctx3 ) =
                                    boxIfNeeded result.ctx result.resultVar elemType

                                ( consVar, ctx4 ) =
                                    freshVar ctx3

                                ( ctx5, consOp ) =
                                    ecoConstruct ctx4 consVar 1 2 0 [ ( boxedVar, ecoValue ), ( tailVar, ecoValue ) ]
                            in
                            ( accOps ++ result.ops ++ boxOps ++ [ consOp ], consVar, ctx5 )
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
                        (ArrayAttr Nothing (List.map (\_ -> TypeAttr ecoValue) captureVarNames))

            papAttrs =
                Dict.union operandTypesAttr
                    (Dict.fromList
                        [ ( "function", SymbolRefAttr (lambdaIdToString closureInfo.lambdaId) )
                        , ( "arity", IntAttr Nothing arity )
                        , ( "num_captured", IntAttr Nothing numCaptured )
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


{-| Generate a Char unary operation (i16 -> i16) with direct kernel call.
-}
generateCharUnaryOp : Context -> List MlirOp -> String -> String -> ExprResult
generateCharUnaryOp ctx argOps charVar kernelName =
    let
        ( resVar, ctx2 ) =
            freshVar ctx

        ( ctx3, callOp ) =
            ecoCallNamed ctx2 resVar kernelName [ ( charVar, I16 ) ] I16
    in
    { ops = argOps ++ [ callOp ]
    , resultVar = resVar
    , ctx = ctx3
    }


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
                Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr mlirTy ])

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


{-| Box or unbox arguments to match the function's expected parameter types.
If the function expects !eco.value but we have an unboxed type, box it.
If the function expects an unboxed type but we have !eco.value, unbox it.
-}
boxToMatchSignature :
    Context
    -> List Mono.MonoExpr
    -> List String
    -> List Mono.MonoType
    -> ( List MlirOp, List ( String, MlirType ), Context )
boxToMatchSignature ctx args argVars expectedTypes =
    let
        helper :
            ( Mono.MonoExpr, String, Mono.MonoType )
            -> ( List MlirOp, List ( String, MlirType ), Context )
            -> ( List MlirOp, List ( String, MlirType ), Context )
        helper ( expr, var, expectedTy ) ( opsAcc, pairsAcc, ctxAcc ) =
            let
                exprMlirTy =
                    monoTypeToMlir (Mono.typeOf expr)

                expectedMlirTy =
                    monoTypeToMlir expectedTy
            in
            if expectedMlirTy == exprMlirTy then
                -- Types match, no boxing/unboxing needed
                ( opsAcc, pairsAcc ++ [ ( var, exprMlirTy ) ], ctxAcc )

            else if isEcoValueType expectedMlirTy && not (isEcoValueType exprMlirTy) then
                -- Function expects boxed, we have unboxed -> box it
                let
                    ( boxOps, boxedVar, ctx1 ) =
                        boxIfNeeded ctxAcc var (Mono.typeOf expr)
                in
                ( opsAcc ++ boxOps, pairsAcc ++ [ ( boxedVar, ecoValue ) ], ctx1 )

            else if not (isEcoValueType expectedMlirTy) && isEcoValueType exprMlirTy then
                -- Function expects unboxed, we have boxed -> unbox it
                let
                    ( unboxOps, unboxedVar, ctx1 ) =
                        unboxToType ctxAcc var expectedMlirTy
                in
                ( opsAcc ++ unboxOps, pairsAcc ++ [ ( unboxedVar, expectedMlirTy ) ], ctx1 )

            else
                -- Types don't match but no boxing solution - use expression type
                ( opsAcc, pairsAcc ++ [ ( var, exprMlirTy ) ], ctxAcc )

        zipped =
            List.map3 (\a b c -> ( a, b, c )) args argVars expectedTypes
    in
    List.foldl helper ( [], [], ctx ) zipped


{-| Unbox a boxed !eco.value to a specific primitive type.
-}
unboxToType : Context -> String -> MlirType -> ( List MlirOp, String, Context )
unboxToType ctx var targetType =
    let
        ( unboxedVar, ctx1 ) =
            freshVar ctx

        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr ecoValue ])

        ( ctx2, unboxOp ) =
            mlirOp ctx1 "eco.unbox"
                |> opBuilder.withOperands [ var ]
                |> opBuilder.withResults [ ( unboxedVar, targetType ) ]
                |> opBuilder.withAttrs attrs
                |> opBuilder.build
    in
    ( [ unboxOp ], unboxedVar, ctx2 )


generateCall : Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateCall ctx func args resultType =
    case func of
        Mono.MonoVarGlobal _ specId funcType ->
            let
                ( argOps, argVars, ctx1 ) =
                    generateExprList ctx args

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

                        Nothing ->
                            Nothing
            in
            case maybeCoreInfo of
                Just ( moduleName, name ) ->
                    -- This is a core module function - check for intrinsic
                    case kernelIntrinsic moduleName name argTypes resultType of
                        Just intrinsic ->
                            -- Generate intrinsic operation directly
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
                            -- No intrinsic match - check if we should use kernel or compiled function
                            if hasKernelImplementation moduleName name then
                                -- Fall back to kernel call (e.g., negate with boxed values)
                                let
                                    sig : FuncSignature
                                    sig =
                                        kernelFuncSignatureFromType funcType

                                    ( boxOps, argVarPairs, ctx1b ) =
                                        boxToMatchSignature ctx1 args argVars sig.paramTypes

                                    ( resVar, ctx2 ) =
                                        freshVar ctx1b

                                    kernelName : String
                                    kernelName =
                                        "Elm_Kernel_" ++ moduleName ++ "_" ++ name

                                    ( ctx3, callOp ) =
                                        ecoCallNamed ctx2 resVar kernelName argVarPairs (monoTypeToMlir sig.returnType)
                                in
                                { ops = argOps ++ boxOps ++ [ callOp ]
                                , resultVar = resVar
                                , ctx = ctx3
                                }

                            else
                                -- Fall back to compiled function call (e.g., min, max, abs, compare)
                                let
                                    funcName : String
                                    funcName =
                                        specIdToFuncName ctx.registry specId

                                    maybeSig : Maybe FuncSignature
                                    maybeSig =
                                        Dict.get specId ctx.signatures

                                    ( boxOps, argVarPairs, ctx1b ) =
                                        case maybeSig of
                                            Just sig ->
                                                boxToMatchSignature ctx1 args argVars sig.paramTypes

                                            Nothing ->
                                                ( []
                                                , List.map2
                                                    (\expr var -> ( var, monoTypeToMlir (Mono.typeOf expr) ))
                                                    args
                                                    argVars
                                                , ctx1
                                                )

                                    ( resultVar, ctx2 ) =
                                        freshVar ctx1b

                                    ( ctx3, callOp ) =
                                        ecoCallNamed ctx2 resultVar funcName argVarPairs (monoTypeToMlir resultType)
                                in
                                { ops = argOps ++ boxOps ++ [ callOp ]
                                , resultVar = resultVar
                                , ctx = ctx3
                                }

                Nothing ->
                    -- Regular function call (not a core module)
                    let
                        funcName : String
                        funcName =
                            specIdToFuncName ctx.registry specId

                        -- Look up the function signature to determine expected parameter types
                        maybeSig : Maybe FuncSignature
                        maybeSig =
                            Dict.get specId ctx.signatures

                        -- Compute argument pairs based on whether we have a signature
                        ( boxOps, argVarPairs, ctx1b ) =
                            case maybeSig of
                                Just sig ->
                                    -- Use the function's parameter types
                                    -- Box if function expects ecoValue but we have primitive
                                    boxToMatchSignature ctx1 args argVars sig.paramTypes

                                Nothing ->
                                    -- No signature available, use expression types (original behavior)
                                    ( []
                                    , List.map2
                                        (\expr var -> ( var, monoTypeToMlir (Mono.typeOf expr) ))
                                        args
                                        argVars
                                    , ctx1
                                    )

                        ( resultVar, ctx2 ) =
                            freshVar ctx1b

                        ( ctx3, callOp ) =
                            ecoCallNamed ctx2 resultVar funcName argVarPairs (monoTypeToMlir resultType)
                    in
                    { ops = argOps ++ boxOps ++ [ callOp ]
                    , resultVar = resultVar
                    , ctx = ctx3
                    }

        Mono.MonoVarKernel _ home name funcType ->
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

                        ( resVar, _ ) =
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
                            -- Check if this is a polymorphic kernel function (e.g., Debug.log)
                            -- For polymorphic kernels, all arguments must be boxed as !eco.value
                            if isPolymorphicKernel home name then
                                let
                                    argsWithTypes : List ( String, Mono.MonoType )
                                    argsWithTypes =
                                        List.map2 (\expr var -> ( var, Mono.typeOf expr )) args argVars

                                    ( boxOps, boxedVars, ctx1b ) =
                                        boxArgsIfNeeded ctx1 argsWithTypes

                                    ( resVar, ctx2 ) =
                                        freshVar ctx1b

                                    kernelName : String
                                    kernelName =
                                        "Elm_Kernel_" ++ home ++ "_" ++ name

                                    ( ctx3, callOp ) =
                                        ecoCallNamed ctx2 resVar kernelName (List.map (\v -> ( v, ecoValue )) boxedVars) ecoValue
                                in
                                { ops = argOps ++ boxOps ++ [ callOp ]
                                , resultVar = resVar
                                , ctx = ctx3
                                }

                            else
                                -- Generic kernel ABI path: derive signature from Elm type
                                let
                                    sig : FuncSignature
                                    sig =
                                        kernelFuncSignatureFromType funcType

                                    -- Use boxToMatchSignature which handles both boxing AND unboxing
                                    -- based on the ABI types derived from sig.paramTypes
                                    ( boxOps, argVarPairs, ctx1b ) =
                                        boxToMatchSignature ctx1 args argVars sig.paramTypes

                                    ( resVar, ctx2 ) =
                                        freshVar ctx1b

                                    kernelName : String
                                    kernelName =
                                        "Elm_Kernel_" ++ home ++ "_" ++ name

                                    ( ctx3, callOp ) =
                                        ecoCallNamed ctx2 resVar kernelName argVarPairs (monoTypeToMlir sig.returnType)
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
                    lookupVar ctx name :: boxedVars

                allOperandTypes : List MlirType
                allOperandTypes =
                    List.map (\_ -> ecoValue) allOperandNames

                remainingArity : Int
                remainingArity =
                    functionArity resultType

                papExtendAttrs =
                    Dict.fromList
                        [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                        , ( "remaining_arity", IntAttr Nothing remainingArity )
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
                        [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                        , ( "remaining_arity", IntAttr Nothing remainingArity )
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
                [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr argVarTypes) )
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



-- IF GENERATION


{-| Generate if expressions using eco.case on Bool.

Compiles `if c1 then t1 else if c2 then t2 else ... final` to nested
eco.case operations on boolean conditions.

-}
generateIf : Context -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> Mono.MonoExpr -> ExprResult
generateIf ctx branches final =
    case branches of
        [] ->
            generateExpr ctx final

        ( condExpr, thenExpr ) :: restBranches ->
            let
                -- Evaluate condition to Bool
                condRes =
                    generateExpr ctx condExpr

                condVar =
                    condRes.resultVar

                -- Get result type from the then branch
                resultMonoType =
                    Mono.typeOf thenExpr

                resultMlirType =
                    monoTypeToMlir resultMonoType

                -- Generate then branch with eco.return
                thenRes =
                    generateExpr condRes.ctx thenExpr

                ( ctx1, thenRetOp ) =
                    ecoReturn thenRes.ctx thenRes.resultVar resultMlirType

                thenRegion =
                    mkRegion [] thenRes.ops thenRetOp

                -- Generate else branch (recursive if or final) with eco.return
                elseRes =
                    generateIf ctx1 restBranches final

                ( ctx2, elseRetOp ) =
                    ecoReturn elseRes.ctx elseRes.resultVar resultMlirType

                elseRegion =
                    mkRegion [] elseRes.ops elseRetOp

                -- eco.case on Bool: tag 1 for True (then), tag 0 for False (else)
                ( ctx3, caseOp ) =
                    ecoCase ctx2 condVar [ 1, 0 ] [ thenRegion, elseRegion ] [ resultMlirType ]
            in
            -- Use condVar as placeholder - the lowering will replace everything
            { ops = condRes.ops ++ [ caseOp ]
            , resultVar = condVar
            , ctx = ctx3
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

                -- Instead of creating an eco.construct wrapper, just add a mapping
                -- from the let-bound name to the expression's result variable.
                -- This preserves the original type and avoids boxing issues.
                ctx1 : Context
                ctx1 =
                    addVarMapping name exprResult.resultVar exprResult.ctx

                bodyResult : ExprResult
                bodyResult =
                    generateExpr ctx1 body
            in
            { ops = exprResult.ops ++ bodyResult.ops
            , resultVar = bodyResult.resultVar
            , ctx = bodyResult.ctx
            }

        Mono.MonoTailDef _ _ ->
            generateExpr ctx body



-- DESTRUCT GENERATION (kept as in original)


generateDestruct : Context -> Mono.MonoDestructor -> Mono.MonoExpr -> ExprResult
generateDestruct ctx (Mono.MonoDestructor name path monoType) body =
    let
        targetType =
            monoTypeToMlir monoType

        ( pathOps, pathVar, ctx1 ) =
            generateMonoPath ctx path targetType

        -- Use mapping instead of eco.construct wrapper
        ctx2 : Context
        ctx2 =
            addVarMapping name pathVar ctx1

        bodyResult : ExprResult
        bodyResult =
            generateExpr ctx2 body
    in
    { ops = pathOps ++ bodyResult.ops
    , resultVar = bodyResult.resultVar
    , ctx = bodyResult.ctx
    }


generateMonoPath : Context -> Mono.MonoPath -> MlirType -> ( List MlirOp, String, Context )
generateMonoPath ctx path targetType =
    case path of
        Mono.MonoRoot name ->
            ( [], lookupVar ctx name, ctx )

        Mono.MonoIndex index subPath ->
            let
                -- Intermediate projections always produce !eco.value
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath ecoValue

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, projectOp ) =
                    ecoProject ctx2 resultVar index ecoValue subVar ecoValue
            in
            ( subOps ++ [ projectOp ]
            , resultVar
            , ctx3
            )

        Mono.MonoField index subPath ->
            let
                -- Intermediate projections always produce !eco.value
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath ecoValue

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, projectOp ) =
                    ecoProject ctx2 resultVar index ecoValue subVar ecoValue
            in
            ( subOps ++ [ projectOp ]
            , resultVar
            , ctx3
            )

        Mono.MonoUnbox subPath ->
            -- First get the boxed value from subpath
            let
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath ecoValue

                ( unboxOps, unboxedVar, ctx2 ) =
                    unboxToType ctx1 subVar targetType
            in
            ( subOps ++ unboxOps
            , unboxedVar
            , ctx2
            )



-- DECISION TREE PATH GENERATION


{-| Generate MLIR ops to navigate a DT.Path from the root scrutinee.

Returns the ops needed to project to the target, the result variable name,
and the updated context.

The targetType parameter specifies what type the final value should be:
- For primitive tests (IsBool, IsInt, IsChr), this is the primitive type
- For ctor tests, this is !eco.value

-}
generateDTPath : Context -> Name.Name -> DT.Path -> MlirType -> ( List MlirOp, String, Context )
generateDTPath ctx root dtPath targetType =
    case dtPath of
        DT.Empty ->
            ( [], "%" ++ root, ctx )

        DT.Index index subPath ->
            let
                -- Intermediate projections always produce !eco.value
                ( subOps, subVar, ctx1 ) =
                    generateDTPath ctx root subPath ecoValue

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, projectOp ) =
                    ecoProject ctx2 resultVar (Index.toMachine index) ecoValue subVar ecoValue
            in
            ( subOps ++ [ projectOp ], resultVar, ctx3 )

        DT.Unbox subPath ->
            -- Unbox the value to the target primitive type
            let
                ( subOps, subVar, ctx1 ) =
                    generateDTPath ctx root subPath ecoValue

                ( unboxOps, unboxedVar, ctx2 ) =
                    unboxToType ctx1 subVar targetType
            in
            ( subOps ++ unboxOps, unboxedVar, ctx2 )


{-| Generate MLIR ops to evaluate a DT.Test, returning a boolean result.

For constructor tests (IsCtor), we return the value to be tested with eco.case directly.
For other tests (IsBool, IsInt, etc.), we generate comparison ops that produce a boolean.

-}
generateTest : Context -> Name.Name -> ( DT.Path, DT.Test ) -> ( List MlirOp, String, Context )
generateTest ctx root ( path, test ) =
    let
        -- Determine target type based on the test
        targetType =
            case test of
                DT.IsCtor _ _ _ _ _ ->
                    ecoValue

                DT.IsBool _ ->
                    I1

                DT.IsInt _ ->
                    I64

                DT.IsChr _ ->
                    ecoChar

                DT.IsStr _ ->
                    ecoValue

                DT.IsCons ->
                    ecoValue

                DT.IsNil ->
                    ecoValue

                DT.IsTuple ->
                    ecoValue

        ( pathOps, valVar, ctx1 ) =
            generateDTPath ctx root path targetType
    in
    case test of
        DT.IsCtor _ _ _ _ _ ->
            -- For ctor tests, we rely on eco.case; just return the value
            ( pathOps, valVar, ctx1 )

        DT.IsBool expected ->
            -- valVar is a Bool; if expected is False, invert it
            if expected then
                ( pathOps, valVar, ctx1 )

            else
                let
                    ( resVar, ctx2 ) =
                        freshVar ctx1

                    -- Invert boolean: result = 1 - valVar (xor with 1)
                    ( constVar, ctx3 ) =
                        freshVar ctx2

                    ( ctx4, constOp ) =
                        arithConstantBool ctx3 constVar True

                    ( ctx5, xorOp ) =
                        ecoBinaryOp ctx4 "arith.xori" resVar ( valVar, I1 ) ( constVar, I1 ) I1
                in
                ( pathOps ++ [ constOp, xorOp ], resVar, ctx5 )

        DT.IsInt i ->
            let
                ( constVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, constOp ) =
                    arithConstantInt ctx2 constVar i

                ( resVar, ctx4 ) =
                    freshVar ctx3

                ( ctx5, cmpOp ) =
                    ecoBinaryOp ctx4 "eco.int.eq" resVar ( valVar, I64 ) ( constVar, I64 ) I1
            in
            ( pathOps ++ [ constOp, cmpOp ], resVar, ctx5 )

        DT.IsChr c ->
            -- Compare character codes
            let
                charCode =
                    String.toList c |> List.head |> Maybe.map Char.toCode |> Maybe.withDefault 0

                ( constVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, constOp ) =
                    arithConstantChar ctx2 constVar charCode

                ( resVar, ctx4 ) =
                    freshVar ctx3

                ( ctx5, cmpOp ) =
                    ecoBinaryOp ctx4 "arith.cmpi" resVar ( valVar, ecoChar ) ( constVar, ecoChar ) I1
            in
            ( pathOps ++ [ constOp, cmpOp ], resVar, ctx5 )

        DT.IsStr s ->
            -- String comparison - use kernel function
            let
                ( strVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, strOp ) =
                    ecoStringLiteral ctx2 strVar s

                ( resVar, ctx4 ) =
                    freshVar ctx3

                ( ctx5, cmpOp ) =
                    ecoCallNamed ctx4 resVar "Elm_Kernel_Utils_equal" [ ( valVar, ecoValue ), ( strVar, ecoValue ) ] I1
            in
            ( pathOps ++ [ strOp, cmpOp ], resVar, ctx5 )

        DT.IsCons ->
            -- Test if list is non-empty (tag == 1)
            let
                ( tagVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, tagOp ) =
                    ecoGetTag ctx2 tagVar valVar

                ( constVar, ctx4 ) =
                    freshVar ctx3

                ( ctx5, constOp ) =
                    arithConstantInt ctx4 constVar 1

                ( resVar, ctx6 ) =
                    freshVar ctx5

                ( ctx7, cmpOp ) =
                    ecoBinaryOp ctx6 "eco.int.eq" resVar ( tagVar, I64 ) ( constVar, I64 ) I1
            in
            ( pathOps ++ [ tagOp, constOp, cmpOp ], resVar, ctx7 )

        DT.IsNil ->
            -- Test if list is empty (tag == 0)
            let
                ( tagVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, tagOp ) =
                    ecoGetTag ctx2 tagVar valVar

                ( constVar, ctx4 ) =
                    freshVar ctx3

                ( ctx5, constOp ) =
                    arithConstantInt ctx4 constVar 0

                ( resVar, ctx6 ) =
                    freshVar ctx5

                ( ctx7, cmpOp ) =
                    ecoBinaryOp ctx6 "eco.int.eq" resVar ( tagVar, I64 ) ( constVar, I64 ) I1
            in
            ( pathOps ++ [ tagOp, constOp, cmpOp ], resVar, ctx7 )

        DT.IsTuple ->
            -- Tuples always match (we just need the value)
            let
                ( resVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, constOp ) =
                    arithConstantBool ctx2 resVar True
            in
            ( pathOps ++ [ constOp ], resVar, ctx3 )


{-| Generate the condition for a Chain node by ANDing all test booleans.
-}
generateChainCondition : Context -> Name.Name -> List ( DT.Path, DT.Test ) -> ( List MlirOp, String, Context )
generateChainCondition ctx root tests =
    case tests of
        [] ->
            -- No tests means always true
            let
                ( resVar, ctx1 ) =
                    freshVar ctx

                ( ctx2, constOp ) =
                    arithConstantBool ctx1 resVar True
            in
            ( [ constOp ], resVar, ctx2 )

        [ singleTest ] ->
            generateTest ctx root singleTest

        firstTest :: restTests ->
            let
                ( firstOps, firstVar, ctx1 ) =
                    generateTest ctx root firstTest

                ( restOps, restVar, ctx2 ) =
                    generateChainCondition ctx1 root restTests

                ( resVar, ctx3 ) =
                    freshVar ctx2

                ( ctx4, andOp ) =
                    ecoBinaryOp ctx3 "arith.andi" resVar ( firstVar, I1 ) ( restVar, I1 ) I1
            in
            ( firstOps ++ restOps ++ [ andOp ], resVar, ctx4 )


{-| Get the tag from a DT.Test for use with eco.case
-}
testToTagInt : DT.Test -> Int
testToTagInt test =
    case test of
        DT.IsCtor _ _ index _ _ ->
            Index.toMachine index

        DT.IsCons ->
            1

        DT.IsNil ->
            0

        DT.IsBool True ->
            1

        DT.IsBool False ->
            0

        DT.IsInt i ->
            i

        DT.IsChr c ->
            String.toList c |> List.head |> Maybe.map Char.toCode |> Maybe.withDefault 0

        DT.IsStr _ ->
            0

        DT.IsTuple ->
            0


{-| Compute the fallback tag for a fan-out based on the edge tests.
For two-way branches (Bool, Cons/Nil), this computes the "other" tag.
For N-way branches (custom types), this finds the first missing tag.
-}
computeFallbackTag : List DT.Test -> Int
computeFallbackTag edgeTests =
    case edgeTests of
        [ DT.IsBool True ] ->
            0

        [ DT.IsBool False ] ->
            1

        [ DT.IsCons ] ->
            0

        [ DT.IsNil ] ->
            1

        _ ->
            -- For custom types with multiple edges, find the first unused tag
            let
                usedTags =
                    List.map testToTagInt edgeTests

                maxTag =
                    List.maximum usedTags |> Maybe.withDefault 0
            in
            -- Find first unused tag from 0 to maxTag+1
            List.range 0 (maxTag + 1)
                |> List.filter (\t -> not (List.member t usedTags))
                |> List.head
                |> Maybe.withDefault (maxTag + 1)



-- CASE GENERATION


{-| Generate shared joinpoints for case branches that are referenced multiple times.

Each (index, branchExpr) in jumps becomes an eco.joinpoint that can be jumped to
from multiple leaves in the decision tree.

-}
generateSharedJoinpoints : Context -> List ( Int, Mono.MonoExpr ) -> MlirType -> ( Context, List MlirOp )
generateSharedJoinpoints ctx jumps resultTy =
    List.foldl
        (\( index, branchExpr ) ( accCtx, accOps ) ->
            let
                -- Body: generate the branch expression, then eco.return
                branchRes =
                    generateExpr accCtx branchExpr

                ( ctx1, retOp ) =
                    ecoReturn branchRes.ctx branchRes.resultVar resultTy

                jpRegion =
                    mkRegion [] branchRes.ops retOp

                -- Continuation: a dummy region with a return (joinpoint semantics require it)
                ( dummyVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, dummyConstructOp ) =
                    ecoConstruct ctx2 dummyVar 0 0 0 []

                ( ctx4, dummyRetOp ) =
                    ecoReturn ctx3 dummyVar resultTy

                contRegion =
                    mkRegion [] [ dummyConstructOp ] dummyRetOp

                ( ctx5, jpOp ) =
                    ecoJoinpoint ctx4 index [] jpRegion contRegion [ resultTy ]
            in
            ( ctx5, accOps ++ [ jpOp ] )
        )
        ( ctx, [] )
        jumps


{-| Generate the decision tree control flow for a case expression.
-}
generateDecider : Context -> Name.Name -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
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
generateLeaf : Context -> Name.Name -> Mono.MonoChoice -> MlirType -> ExprResult
generateLeaf ctx _ choice resultTy =
    case choice of
        Mono.Inline branchExpr ->
            -- Evaluate the branch expression and return it
            let
                branchRes =
                    generateExpr ctx branchExpr

                ( ctx1, retOp ) =
                    ecoReturn branchRes.ctx branchRes.resultVar resultTy
            in
            -- The return op MUST be last so mkRegionFromOps picks it as terminator
            { ops = branchRes.ops ++ [ retOp ]
            , resultVar = branchRes.resultVar
            , ctx = ctx1
            }

        Mono.Jump index ->
            -- Jump to the shared joinpoint
            let
                ( ctx1, jumpOp ) =
                    ecoJump ctx index []

                -- Return a dummy result
                ( dummyVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, dummyOp ) =
                    ecoConstruct ctx2 dummyVar 0 0 0 []
            in
            { ops = [ jumpOp, dummyOp ]
            , resultVar = dummyVar
            , ctx = ctx3
            }


{-| Generate code for a Chain node (test chain with success/failure branches).
-}
generateChain : Context -> Name.Name -> List ( DT.Path, DT.Test ) -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateChain ctx root testChain success failure resultTy =
    let
        -- Compute the boolean condition
        ( condOps, condVar, ctx1 ) =
            generateChainCondition ctx root testChain

        -- Generate success branch
        thenRes =
            generateDecider ctx1 root success resultTy

        -- Generate failure branch
        elseRes =
            generateDecider thenRes.ctx root failure resultTy

        -- Build regions for eco.case on Bool
        -- Note: thenRes.ops and elseRes.ops already contain eco.return (from generateLeaf or recursion)
        thenRegion =
            mkRegionFromOps thenRes.ops

        elseRegion =
            mkRegionFromOps elseRes.ops

        -- eco.case on Bool: tag 1 for True (then), tag 0 for False (else)
        ( ctx2, caseOp ) =
            ecoCase elseRes.ctx condVar [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]
    in
    -- Use condVar as placeholder - the lowering will replace everything
    { ops = condOps ++ [ caseOp ]
    , resultVar = condVar
    , ctx = ctx2
    }


{-| Generate code for a FanOut node (multi-way branching on constructor tags).
-}
generateFanOut : Context -> Name.Name -> DT.Path -> List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateFanOut ctx root path edges fallback resultTy =
    let
        -- Get the scrutinee value at the path
        -- FanOut is for constructor branching, so we want !eco.value
        ( pathOps, scrutineeVar, ctx1 ) =
            generateDTPath ctx root path ecoValue

        -- Collect tags from edges
        edgeTags =
            List.map (\( test, _ ) -> testToTagInt test) edges

        -- Compute the fallback tag (for the fallback region)
        edgeTests =
            List.map Tuple.first edges

        fallbackTag =
            computeFallbackTag edgeTests

        -- All tags including the fallback
        tags =
            edgeTags ++ [ fallbackTag ]

        -- Generate regions for each edge
        ( edgeRegions, ctx2 ) =
            List.foldl
                (\( _, subTree ) ( accRegions, accCtx ) ->
                    let
                        subRes =
                            generateDecider accCtx root subTree resultTy

                        region =
                            mkRegionFromOps subRes.ops
                    in
                    ( accRegions ++ [ region ], subRes.ctx )
                )
                ( [], ctx1 )
                edges

        -- Generate fallback region
        fallbackRes =
            generateDecider ctx2 root fallback resultTy

        fallbackRegion =
            mkRegionFromOps fallbackRes.ops

        -- Build eco.case with all regions (edges + fallback)
        allRegions =
            edgeRegions ++ [ fallbackRegion ]

        ( ctx3, caseOp ) =
            ecoCase fallbackRes.ctx scrutineeVar tags allRegions [ resultTy ]
    in
    -- Return the case op - no dummy construct between case and return!
    -- The lowering pattern expects: eco.case ... eco.return
    -- Use scrutineeVar as placeholder resultVar - the lowering will replace everything
    { ops = pathOps ++ [ caseOp ]
    , resultVar = scrutineeVar
    , ctx = ctx3
    }


{-| Helper to build a region from a list of ops (where the last op is the terminator).
-}
mkRegionFromOps : List MlirOp -> MlirRegion
mkRegionFromOps ops =
    case List.reverse ops of
        [] ->
            -- Empty region - shouldn't happen but handle gracefully
            MlirRegion
                { entry = { args = [], body = [], terminator = defaultTerminator }
                , blocks = OrderedDict.empty
                }

        terminator :: restReversed ->
            MlirRegion
                { entry = { args = [], body = List.reverse restReversed, terminator = terminator }
                , blocks = OrderedDict.empty
                }


{-| A default terminator for empty regions (unreachable).
-}
defaultTerminator : MlirOp
defaultTerminator =
    { id = "unreachable"
    , name = "eco.unreachable"
    , operands = []
    , regions = []
    , results = []
    , successors = []
    , attrs = Dict.empty
    , loc = Loc.unknown
    , isTerminator = True
    }


{-| Generate case expression control flow.

This is the main entry point for case expressions. It:

1.  Emits joinpoints for shared branches
2.  Generates the decision tree control flow
3.  Returns a dummy ExprResult (since real control exits via eco.return/eco.jump)

-}
generateCase : Context -> Name.Name -> Name.Name -> Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> Mono.MonoType -> ExprResult
generateCase ctx _ root decider jumps resultMonoType =
    let
        resultMlirType =
            monoTypeToMlir resultMonoType

        -- Emit joinpoints for shared branches
        ( ctx1, joinpointOps ) =
            generateSharedJoinpoints ctx jumps resultMlirType

        -- Generate decision tree control flow
        decisionResult =
            generateDecider ctx1 root decider resultMlirType
    in
    { ops = joinpointOps ++ decisionResult.ops
    , resultVar = decisionResult.resultVar
    , ctx = decisionResult.ctx
    }



-- RECORD GENERATION


generateRecordCreate : Context -> List Mono.MonoExpr -> Mono.RecordLayout -> ExprResult
generateRecordCreate ctx fields layout =
    let
        ( fieldsOps, fieldVars, ctx1 ) =
            generateExprList ctx fields

        -- Pair field vars with their expression types
        fieldVarsWithTypes : List ( String, Mono.MonoType )
        fieldVarsWithTypes =
            List.map2 (\v expr -> ( v, Mono.typeOf expr )) fieldVars fields

        -- Box fields that need to be boxed (layout says boxed, but expression is primitive)
        ( boxOps, boxedFieldVars, ctx2 ) =
            List.foldl
                (\( ( var, exprType ), fieldInfo ) ( opsAcc, varsAcc, ctxAcc ) ->
                    if fieldInfo.isUnboxed then
                        -- Field is stored unboxed, use as-is
                        ( opsAcc, varsAcc ++ [ var ], ctxAcc )

                    else
                        -- Field should be boxed - box if needed
                        let
                            ( moreOps, boxedVar, newCtx ) =
                                boxIfNeeded ctxAcc var exprType
                        in
                        ( opsAcc ++ moreOps, varsAcc ++ [ boxedVar ], newCtx )
                )
                ( [], [], ctx1 )
                (List.map2 Tuple.pair fieldVarsWithTypes layout.fields)

        ( resultVar, ctx3 ) =
            freshVar ctx2

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
                boxedFieldVars
                layout.fields

        ( ctx4, constructOp ) =
            ecoConstruct ctx3 resultVar 0 layout.fieldCount layout.unboxedBitmap fieldVarPairs
    in
    { ops = fieldsOps ++ boxOps ++ [ constructOp ]
    , resultVar = resultVar
    , ctx = ctx4
    }


generateRecordAccess : Context -> Mono.MonoExpr -> Name.Name -> Int -> Bool -> Mono.MonoType -> ExprResult
generateRecordAccess ctx record _ index isUnboxed fieldType =
    let
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record

        ( projectVar, ctx1 ) =
            freshVar recordResult.ctx

        -- Determine the MLIR type for the field
        fieldMlirType =
            monoTypeToMlir fieldType
    in
    if isUnboxed then
        -- Field is stored unboxed - project directly to the primitive type
        let
            ( ctx2, projectOp ) =
                ecoProject ctx1 projectVar index fieldMlirType recordResult.resultVar ecoValue
        in
        { ops = recordResult.ops ++ [ projectOp ]
        , resultVar = projectVar
        , ctx = ctx2
        }

    else if isEcoValueType fieldMlirType then
        -- Field is boxed and semantic type is also !eco.value - just project
        let
            ( ctx2, projectOp ) =
                ecoProject ctx1 projectVar index ecoValue recordResult.resultVar ecoValue
        in
        { ops = recordResult.ops ++ [ projectOp ]
        , resultVar = projectVar
        , ctx = ctx2
        }

    else
        -- Field is stored boxed but semantic type is primitive
        -- Project to get !eco.value, then unbox to primitive type
        let
            ( ctx2, projectOp ) =
                ecoProject ctx1 projectVar index ecoValue recordResult.resultVar ecoValue

            ( unboxOps, unboxedVar, ctx3 ) =
                unboxToType ctx2 projectVar fieldMlirType
        in
        { ops = recordResult.ops ++ [ projectOp ] ++ unboxOps
        , resultVar = unboxedVar
        , ctx = ctx3
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
                , ( "arity", IntAttr Nothing 1 )
                , ( "num_captured", IntAttr Nothing 0 )
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
                    (ArrayAttr Nothing (List.map (\( _, t ) -> TypeAttr t) operands))

        attrs =
            Dict.union operandTypesAttr
                (Dict.fromList
                    [ ( "tag", IntAttr Nothing tag )
                    , ( "size", IntAttr Nothing size )
                    , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
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
                    (ArrayAttr Nothing (List.map (\( _, t ) -> TypeAttr t) operands))

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

    The resultType should be the actual type of the extracted field:
    - i64 for Int fields
    - f64 for Float fields
    - i1 for Bool fields
    - i16 for Char fields
    - !eco.value for boxed fields
-}
ecoProject : Context -> String -> Int -> MlirType -> String -> MlirType -> ( Context, MlirOp )
ecoProject ctx resultVar index resultType operand operandType =
    let
        isUnboxed =
            not (isEcoValueType resultType)

        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr operandType ] )
                , ( "index", IntAttr Nothing index )
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
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr operandType ])
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
        |> opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I64) value))
        |> opBuilder.build


{-| arith.constant for floats
-}
arithConstantFloat : Context -> String -> Float -> ( Context, MlirOp )
arithConstantFloat ctx resultVar value =
    let
        valueAttr =
            TypedFloatAttr value F64
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
        |> opBuilder.withResults [ ( resultVar, ecoChar ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just ecoChar) codepoint))
        |> opBuilder.build


{-| Build a unary eco op (e.g., eco.int.negate, eco.float.sqrt)
-}
ecoUnaryOp : Context -> String -> String -> ( String, MlirType ) -> MlirType -> ( Context, MlirOp )
ecoUnaryOp ctx opName resultVar ( operand, operandTy ) resultTy =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr operandTy ])
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
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr lhsTy, TypeAttr rhsTy ])
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


{-| eco.case - pattern matching control flow

Takes a scrutinee SSA name, list of tags, list of regions (one per alternative),
and result types. Emits an eco.case operation.

-}
ecoCase : Context -> String -> List Int -> List MlirRegion -> List MlirType -> ( Context, MlirOp )
ecoCase ctx scrutinee tags regions resultTypes =
    let
        attrsBase =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr ecoValue ] )
                , ( "tags", ArrayAttr (Just I64) (List.map (\t -> IntAttr Nothing t) tags) )
                ]

        attrs =
            if List.isEmpty resultTypes then
                attrsBase

            else
                Dict.insert "caseResultTypes"
                    (ArrayAttr Nothing (List.map TypeAttr resultTypes))
                    attrsBase
    in
    mlirOp ctx "eco.case"
        |> opBuilder.withOperands [ scrutinee ]
        |> opBuilder.withRegions regions
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.joinpoint - local control-flow join with a body and continuation

Takes a joinpoint id, parameter types, the body region, continuation region,
and result types.

-}
ecoJoinpoint : Context -> Int -> List ( String, MlirType ) -> MlirRegion -> MlirRegion -> List MlirType -> ( Context, MlirOp )
ecoJoinpoint ctx id params jpRegion contRegion resultTypes =
    let
        attrsBase =
            Dict.fromList [ ( "id", IntAttr Nothing id ) ]

        attrs =
            if List.isEmpty resultTypes then
                attrsBase

            else
                Dict.insert "jpResultTypes"
                    (ArrayAttr Nothing (List.map TypeAttr resultTypes))
                    attrsBase

        -- Build the jp region with params
        jpRegionWithParams =
            case jpRegion of
                MlirRegion r ->
                    MlirRegion { r | entry = { args = params, body = r.entry.body, terminator = r.entry.terminator } }
    in
    mlirOp ctx "eco.joinpoint"
        |> opBuilder.withRegions [ jpRegionWithParams, contRegion ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.jump - jump to a joinpoint

Takes the joinpoint id, operands with types, and builds an eco.jump operation.
The result is a terminator operation.

-}
ecoJump : Context -> Int -> List ( String, MlirType ) -> ( Context, MlirOp )
ecoJump ctx targetId operands =
    let
        operandNames =
            List.map Tuple.first operands

        operandTypesAttr =
            if List.isEmpty operands then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map (\( _, t ) -> TypeAttr t) operands))

        attrs =
            Dict.union operandTypesAttr
                (Dict.singleton "target" (IntAttr Nothing targetId))
    in
    mlirOp ctx "eco.jump"
        |> opBuilder.withOperands operandNames
        |> opBuilder.withAttrs attrs
        |> opBuilder.isTerminator True
        |> opBuilder.build


{-| eco.jump for tail-recursive calls - jump to a named target (function entry)

Takes the target name (function), operands with types, and builds an eco.jump operation.

-}
ecoJumpNamed : Context -> String -> List ( String, MlirType ) -> ( Context, MlirOp )
ecoJumpNamed ctx targetName operands =
    let
        operandNames =
            List.map Tuple.first operands

        operandTypesAttr =
            if List.isEmpty operands then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map (\( _, t ) -> TypeAttr t) operands))

        attrs =
            Dict.union operandTypesAttr
                (Dict.singleton "target" (StringAttr targetName))
    in
    mlirOp ctx "eco.jump"
        |> opBuilder.withOperands operandNames
        |> opBuilder.withAttrs attrs
        |> opBuilder.isTerminator True
        |> opBuilder.build


{-| eco.getTag - get the tag from a value (for eco.case scrutinee)
-}
ecoGetTag : Context -> String -> String -> ( Context, MlirOp )
ecoGetTag ctx resultVar operand =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr ecoValue ])
    in
    mlirOp ctx "eco.getTag"
        |> opBuilder.withOperands [ operand ]
        |> opBuilder.withResults [ ( resultVar, I64 ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build
