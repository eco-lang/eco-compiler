module Compiler.Generate.CodeGen.MLIR exposing (backend)

{-| MLIR code generation backend for the Monomorphized IR.

This backend generates MLIR from fully specialized, monomorphic code.
All polymorphism has been resolved and layout information is embedded
in the types.


# Backend

@docs backend

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as Name
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.Mode as Mode
import Data.Map as EveryDict
import Dict exposing (Dict)
import Mlir.Loc as Loc exposing (Loc)
import Mlir.Mlir
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

        Mono.MCustom _ _ _ _ ->
            ecoValue

        Mono.MFunction _ _ ->
            ecoValue

        Mono.MVar name _ ->
            crash ("MLIR codegen: unresolved type variable " ++ name ++ " - should have been instantiated")


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
        Mono.MonoDefine expr _ monoType ->
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

        Mono.MonoTailFunc params _ _ monoType ->
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

        Mono.MonoPortIncoming expr _ monoType ->
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

        Mono.MonoPortOutgoing expr _ monoType ->
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

        Mono.MonoManager _ monoType ->
            Just
                { paramTypes = []
                , returnType = monoType
                }

        Mono.MonoCycle _ _ monoType ->
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


{-| Types of intrinsic operations that can be emitted as native eco ops
-}
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


{-| Look up whether a kernel function can be emitted as an intrinsic op.
Returns the intrinsic type if matched, Nothing if it should fall back to a runtime call.
-}
kernelIntrinsic : Name.Name -> Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
kernelIntrinsic home name argTypes resultType =
    case home of
        "Basics" ->
            basicsIntrinsic name argTypes resultType

        "Bitwise" ->
            bitwiseIntrinsic name argTypes resultType

        _ ->
            Nothing


{-| Intrinsics from Basics module
-}
basicsIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
basicsIntrinsic name argTypes resultType =
    case ( name, argTypes, resultType ) of
        -- ===== Constants =====
        ( "pi", [], Mono.MFloat ) ->
            Just (ConstantFloat { value = 3.141592653589793 })

        ( "e", [], Mono.MFloat ) ->
            Just (ConstantFloat { value = 2.718281828459045 })

        -- ===== Integer Arithmetic =====
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

        -- ===== Float Arithmetic =====
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

        -- ===== Trigonometric Functions =====
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

        -- ===== Logarithm =====
        ( "logBase", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            -- logBase is handled specially in generateCall - expanded inline
            Nothing

        ( "log", [ Mono.MFloat ], Mono.MFloat ) ->
            Just (UnaryFloat { op = "eco.float.log" })

        -- ===== Float Classification =====
        ( "isNaN", [ Mono.MFloat ], Mono.MBool ) ->
            Just (FloatClassify { op = "eco.float.isNaN" })

        ( "isInfinite", [ Mono.MFloat ], Mono.MBool ) ->
            Just (FloatClassify { op = "eco.float.isInfinite" })

        -- ===== Type Conversions =====
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

        -- ===== Integer Min/Max =====
        ( "min", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.min" })

        ( "max", [ Mono.MInt, Mono.MInt ], Mono.MInt ) ->
            Just (BinaryInt { op = "eco.int.max" })

        -- ===== Float Min/Max =====
        ( "min", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.min" })

        ( "max", [ Mono.MFloat, Mono.MFloat ], Mono.MFloat ) ->
            Just (BinaryFloat { op = "eco.float.max" })

        -- ===== Integer Comparisons =====
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

        -- ===== Float Comparisons =====
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

        -- Fallback: not an intrinsic
        _ ->
            Nothing


{-| Intrinsics from Bitwise module
-}
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



-- OP BUILDER


type alias OpBuilder =
    { name : String
    , id : String
    , operands : List ( String, MlirType )
    , results : List ( String, MlirType )
    , attrs : Dict String MlirAttr
    , regions : List MlirRegion
    , isTerminator : Bool
    , loc : Loc
    , successors : List String
    }


mlirOp : String -> Context -> OpBuilder
mlirOp name ctx =
    let
        ( opId, _ ) =
            freshOpId ctx
    in
    { name = name
    , id = opId
    , operands = []
    , results = []
    , attrs = Dict.empty
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


withOperands : List ( String, MlirType ) -> OpBuilder -> OpBuilder
withOperands operands builder =
    { builder | operands = operands }


withResult : String -> MlirType -> OpBuilder -> OpBuilder
withResult ssa type_ builder =
    { builder | results = [ ( ssa, type_ ) ] }


withAttr : String -> MlirAttr -> OpBuilder -> OpBuilder
withAttr key value builder =
    { builder | attrs = Dict.insert key value builder.attrs }


withRegion : MlirRegion -> OpBuilder -> OpBuilder
withRegion region builder =
    { builder | regions = [ region ] }


asTerminator : OpBuilder -> OpBuilder
asTerminator builder =
    { builder | isTerminator = True }


build : OpBuilder -> MlirOp
build builder =
    let
        -- Extract just the operand names for MlirOp
        operandNames =
            List.map Tuple.first builder.operands

        -- Store operand types as an attribute for pretty printing
        -- The types are stored as an ArrayAttr of TypeAttrs
        operandTypesAttr =
            if List.isEmpty builder.operands then
                builder.attrs

            else
                Dict.insert "_operand_types"
                    (ArrayAttr (List.map (\( _, t ) -> TypeAttr t) builder.operands))
                    builder.attrs
    in
    { name = builder.name
    , id = builder.id
    , operands = operandNames
    , results = builder.results
    , attrs = operandTypesAttr
    , regions = builder.regions
    , isTerminator = builder.isTerminator
    , loc = builder.loc
    , successors = builder.successors
    }



-- ECO DIALECT OP HELPERS


{-| eco.construct - create a heap object
-}
ecoConstruct : Context -> String -> Int -> Int -> Int -> List ( String, MlirType ) -> MlirOp
ecoConstruct ctx resultVar tag size unboxedBitmap operands =
    mlirOp "eco.construct" ctx
        |> withOperands operands
        |> withResult resultVar ecoValue
        |> withAttr "tag" (IntAttr tag)
        |> withAttr "size" (IntAttr size)
        |> withAttr "unboxed_bitmap" (IntAttr unboxedBitmap)
        |> build


{-| eco.call - call a function by name
-}
ecoCallNamed : Context -> String -> String -> List ( String, MlirType ) -> MlirType -> MlirOp
ecoCallNamed ctx resultVar funcName operands returnType =
    mlirOp "eco.call" ctx
        |> withOperands operands
        |> withResult resultVar returnType
        |> withAttr "callee" (SymbolRefAttr funcName)
        |> build


{-| eco.project - extract a field from a record/custom/tuple
-}
ecoProject : Context -> String -> Int -> Bool -> String -> MlirType -> MlirOp
ecoProject ctx resultVar index isUnboxed operand operandType =
    let
        resultType =
            if isUnboxed then
                I64

            else
                ecoValue
    in
    mlirOp "eco.project" ctx
        |> withOperands [ ( operand, operandType ) ]
        |> withResult resultVar resultType
        |> withAttr "index" (IntAttr index)
        |> withAttr "unboxed" (BoolAttr isUnboxed)
        |> build


{-| eco.return - return a value
-}
ecoReturn : Context -> String -> MlirType -> MlirOp
ecoReturn ctx operand operandType =
    mlirOp "eco.return" ctx
        |> withOperands [ ( operand, operandType ) ]
        |> asTerminator
        |> build


{-| eco.string\_literal - create a string constant
-}
ecoStringLiteral : Context -> String -> String -> MlirOp
ecoStringLiteral ctx resultVar value =
    mlirOp "eco.string_literal" ctx
        |> withResult resultVar ecoValue
        |> withAttr "value" (StringAttr value)
        |> build


{-| arith.constant for integers
-}
arithConstantInt : Context -> String -> Int -> MlirOp
arithConstantInt ctx resultVar value =
    mlirOp "arith.constant" ctx
        |> withResult resultVar I64
        |> withAttr "value" (TypedIntAttr value I64)
        |> build


{-| arith.constant for floats
-}
arithConstantFloat : Context -> String -> Float -> MlirOp
arithConstantFloat ctx resultVar value =
    mlirOp "arith.constant" ctx
        |> withResult resultVar F64
        |> withAttr "value" (FloatAttr value)
        |> build


{-| arith.constant for booleans
-}
arithConstantBool : Context -> String -> Bool -> MlirOp
arithConstantBool ctx resultVar value =
    mlirOp "arith.constant" ctx
        |> withResult resultVar I1
        |> withAttr "value" (BoolAttr value)
        |> build


{-| arith.constant for characters
-}
arithConstantChar : Context -> String -> Int -> MlirOp
arithConstantChar ctx resultVar codepoint =
    mlirOp "arith.constant" ctx
        |> withResult resultVar I32
        |> withAttr "value" (TypedIntAttr codepoint I32)
        |> build


{-| Build a unary eco op (e.g., eco.int.negate, eco.float.sqrt)
-}
ecoUnaryOp : Context -> String -> String -> ( String, MlirType ) -> MlirType -> MlirOp
ecoUnaryOp ctx opName resultVar ( operand, operandTy ) resultTy =
    mlirOp opName ctx
        |> withOperands [ ( operand, operandTy ) ]
        |> withResult resultVar resultTy
        |> build


{-| Build a binary eco op (e.g., eco.int.add, eco.float.mul)
-}
ecoBinaryOp : Context -> String -> String -> ( String, MlirType ) -> ( String, MlirType ) -> MlirType -> MlirOp
ecoBinaryOp ctx opName resultVar ( lhs, lhsTy ) ( rhs, rhsTy ) resultTy =
    mlirOp opName ctx
        |> withOperands [ ( lhs, lhsTy ), ( rhs, rhsTy ) ]
        |> withResult resultVar resultTy
        |> build


{-| Generate an intrinsic op from the Intrinsic descriptor
-}
generateIntrinsicOp : Context -> Intrinsic -> String -> List String -> MlirOp
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


{-| func.func - define a function
-}
funcFunc : Context -> String -> List ( String, MlirType ) -> MlirType -> MlirRegion -> MlirOp
funcFunc ctx funcName args returnType bodyRegion =
    mlirOp "func.func" ctx
        |> withRegion bodyRegion
        |> withAttr "sym_name" (StringAttr funcName)
        |> withAttr "sym_visibility" (VisibilityAttr Private)
        |> withAttr "function_type"
            (TypeAttr
                (FunctionType
                    { inputs = List.map Tuple.second args
                    , results = [ returnType ]
                    }
                )
            )
        |> build


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



-- GENERATE MODULE


generateModule : Mode.Mode -> Mono.MonoGraph -> String
generateModule mode ((Mono.MonoGraph { nodes, main, registry }) as monoGraph) =
    let
        -- Build signatures map for invariant checking before code generation
        signatures : Dict Int FuncSignature
        signatures =
            buildSignatures nodes

        ctx : Context
        ctx =
            initContext mode registry signatures

        -- Generate all nodes (they are already only reachable ones from monomorphization)
        -- Thread context through to collect pending lambdas
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

        -- Process pending lambdas - generate their func.func definitions
        -- Need to iteratively process since lambdas can contain more lambdas
        ( lambdaOps, finalCtx ) =
            processLambdas ctxAfterNodes

        -- Generate main entry point if present
        mainOps : List MlirOp
        mainOps =
            case main of
                Just mainInfo ->
                    generateMainEntry finalCtx mainInfo

                Nothing ->
                    []

        mlirModule : MlirModule
        mlirModule =
            -- Emit lambdas first so they're defined before referenced
            { body = lambdaOps ++ ops ++ mainOps
            , loc = Loc.unknown
            }
    in
    Pretty.ppModule mlirModule


{-| Process pending lambdas and generate their func.func definitions.
This may generate more pending lambdas (nested closures), so we iterate.
-}
processLambdas : Context -> ( List MlirOp, Context )
processLambdas ctx =
    case ctx.pendingLambdas of
        [] ->
            ( [], ctx )

        lambdas ->
            -- Clear pending lambdas before processing (to avoid infinite loop)
            let
                ctxCleared =
                    { ctx | pendingLambdas = [] }

                -- Generate each lambda function
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

                -- Recursively process any new lambdas that were added
                ( moreOps, finalCtx ) =
                    processLambdas ctxAfter
            in
            ( lambdaOps ++ moreOps, finalCtx )


{-| Generate a func.func for a pending lambda.
-}
generateLambdaFunc : Context -> PendingLambda -> ( MlirOp, Context )
generateLambdaFunc ctx lambda =
    let
        -- Build argument pairs: captures come first, then params
        captureArgPairs : List ( String, MlirType )
        captureArgPairs =
            List.map (\( name, _ ) -> ( "%" ++ name, ecoValue )) lambda.captures

        paramArgPairs : List ( String, MlirType )
        paramArgPairs =
            List.map (\( name, ty ) -> ( "%" ++ name, monoTypeToMlir ty )) lambda.params

        allArgPairs : List ( String, MlirType )
        allArgPairs =
            captureArgPairs ++ paramArgPairs

        -- Create context with args bound
        ctxWithArgs : Context
        ctxWithArgs =
            { ctx | nextVar = List.length allArgPairs }

        exprResult : ExprResult
        exprResult =
            generateExpr ctxWithArgs lambda.body

        returnType : MlirType
        returnType =
            monoTypeToMlir (Mono.typeOf lambda.body)

        returnOp : MlirOp
        returnOp =
            ecoReturn exprResult.ctx exprResult.resultVar returnType

        region : MlirRegion
        region =
            mkRegion allArgPairs exprResult.ops returnOp
    in
    ( funcFunc ctx lambda.name allArgPairs returnType region, exprResult.ctx )


generateMainEntry : Context -> Mono.MainInfo -> List MlirOp
generateMainEntry ctx mainInfo =
    case mainInfo of
        Mono.StaticMain mainSpecId ->
            -- Simple main - just call it and return the result
            let
                ( callVar, ctx1 ) =
                    freshVar ctx

                mainFuncName : String
                mainFuncName =
                    specIdToFuncName ctx.registry mainSpecId

                callOp : MlirOp
                callOp =
                    ecoCallNamed ctx1 callVar mainFuncName [] ecoValue

                returnOp : MlirOp
                returnOp =
                    ecoReturn ctx1 callVar ecoValue

                region : MlirRegion
                region =
                    mkRegion [] [ callOp ] returnOp
            in
            [ funcFunc ctx "main" [] ecoValue region ]

        Mono.DynamicMain mainSpecId flagsDecoder ->
            -- Dynamic main (Browser.element, etc.) - needs flags decoder
            let
                -- First generate the flags decoder expression
                decoderResult : ExprResult
                decoderResult =
                    generateExpr ctx flagsDecoder

                -- Then call Elm_Platform_initialize with the decoder and main
                ( mainCallVar, ctx1 ) =
                    freshVar decoderResult.ctx

                mainFuncName : String
                mainFuncName =
                    specIdToFuncName ctx.registry mainSpecId

                mainCallOp : MlirOp
                mainCallOp =
                    ecoCallNamed ctx1 mainCallVar mainFuncName [] ecoValue

                ( initCallVar, ctx2 ) =
                    freshVar ctx1

                -- eco.call to platform initialize with decoder and main result
                initCallOp : MlirOp
                initCallOp =
                    ecoCallNamed ctx2 initCallVar "Elm_Platform_initialize" [ ( decoderResult.resultVar, ecoValue ), ( mainCallVar, ecoValue ) ] ecoValue

                returnOp : MlirOp
                returnOp =
                    ecoReturn ctx2 initCallVar ecoValue

                region : MlirRegion
                region =
                    mkRegion [] (decoderResult.ops ++ [ mainCallOp, initCallOp ]) returnOp
            in
            [ funcFunc ctx "main" [] ecoValue region ]



-- GENERATE NODE


generateNode : Context -> Mono.SpecId -> Mono.MonoNode -> ( MlirOp, Context )
generateNode ctx specId node =
    let
        funcName : String
        funcName =
            specIdToFuncName ctx.registry specId
    in
    case node of
        Mono.MonoDefine expr _ monoType ->
            generateDefine ctx funcName expr monoType

        Mono.MonoTailFunc params expr _ monoType ->
            generateTailFunc ctx funcName params expr monoType

        Mono.MonoCtor ctorLayout monoType ->
            ( generateCtor ctx funcName ctorLayout monoType, ctx )

        Mono.MonoEnum tag monoType ->
            ( generateEnum ctx funcName tag monoType, ctx )

        Mono.MonoExtern monoType ->
            ( generateExtern ctx funcName monoType, ctx )

        Mono.MonoPortIncoming expr _ monoType ->
            generateDefine ctx funcName expr monoType

        Mono.MonoPortOutgoing expr _ monoType ->
            generateDefine ctx funcName expr monoType

        Mono.MonoManager managerInfo monoType ->
            ( generateManager ctx funcName managerInfo monoType, ctx )

        Mono.MonoCycle definitions _ monoType ->
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

                returnOp : MlirOp
                returnOp =
                    ecoReturn exprResult.ctx exprResult.resultVar (monoTypeToMlir monoType)

                region : MlirRegion
                region =
                    mkRegion [] exprResult.ops returnOp
            in
            ( funcFunc ctx funcName [] (monoTypeToMlir monoType) region, exprResult.ctx )


generateClosureFunc : Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ( MlirOp, Context )
generateClosureFunc ctx funcName closureInfo body monoType =
    let
        -- Build arg pairs from params
        argPairs : List ( String, MlirType )
        argPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, monoTypeToMlir ty ))
                closureInfo.params

        -- Create context with args bound
        ctxWithArgs : Context
        ctxWithArgs =
            { ctx | nextVar = List.length closureInfo.params }

        exprResult : ExprResult
        exprResult =
            generateExpr ctxWithArgs body

        -- IMPORTANT: The MLIR func returns the *body type*, not the closure value type.
        returnType : MlirType
        returnType =
            monoTypeToMlir (Mono.typeOf body)

        returnOp : MlirOp
        returnOp =
            ecoReturn exprResult.ctx exprResult.resultVar returnType

        region : MlirRegion
        region =
            mkRegion argPairs exprResult.ops returnOp
    in
    ( funcFunc ctx funcName argPairs returnType region, exprResult.ctx )



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

        returnOp : MlirOp
        returnOp =
            ecoReturn exprResult.ctx exprResult.resultVar (monoTypeToMlir monoType)

        region : MlirRegion
        region =
            mkRegion argPairs exprResult.ops returnOp
    in
    ( funcFunc ctx funcName argPairs (monoTypeToMlir monoType) region, exprResult.ctx )



-- GENERATE CTOR


generateCtor : Context -> String -> Mono.CtorLayout -> Mono.MonoType -> MlirOp
generateCtor ctx funcName ctorLayout monoType =
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

            constructOp : MlirOp
            constructOp =
                ecoConstruct ctx1 resultVar ctorLayout.tag 0 0 []

            returnOp : MlirOp
            returnOp =
                ecoReturn ctx1 resultVar ecoValue

            region : MlirRegion
            region =
                mkRegion [] [ constructOp ] returnOp
        in
        funcFunc ctx funcName [] ecoValue region

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

            constructOp : MlirOp
            constructOp =
                ecoConstruct ctx1 resultVar ctorLayout.tag arity ctorLayout.unboxedBitmap argPairs

            returnOp : MlirOp
            returnOp =
                ecoReturn ctx1 resultVar ecoValue

            region : MlirRegion
            region =
                mkRegion argPairs [ constructOp ] returnOp
        in
        funcFunc ctx funcName argPairs ecoValue region



-- GENERATE ENUM


generateEnum : Context -> String -> Int -> Mono.MonoType -> MlirOp
generateEnum ctx funcName tag monoType =
    let
        ( resultVar, ctx1 ) =
            freshVar ctx

        constructOp : MlirOp
        constructOp =
            ecoConstruct ctx1 resultVar tag 0 0 []

        returnOp : MlirOp
        returnOp =
            ecoReturn ctx1 resultVar ecoValue

        region : MlirRegion
        region =
            mkRegion [] [ constructOp ] returnOp
    in
    funcFunc ctx funcName [] ecoValue region



-- GENERATE EXTERN


generateExtern : Context -> String -> Mono.MonoType -> MlirOp
generateExtern ctx funcName monoType =
    -- Generate an extern declaration (no body)
    mlirOp "func.func" ctx
        |> withAttr "sym_name" (StringAttr funcName)
        |> withAttr "sym_visibility" (VisibilityAttr Private)
        |> withAttr "function_type"
            (TypeAttr
                (FunctionType
                    { inputs = []
                    , results = [ monoTypeToMlir monoType ]
                    }
                )
            )
        |> build



-- GENERATE MANAGER


generateManager : Context -> String -> Mono.ManagerInfo -> Mono.MonoType -> MlirOp
generateManager ctx funcName managerInfo monoType =
    -- Generate an effects manager
    -- This creates a record with init, onEffects, onSelfMsg, and optional cmdMap/subMap
    let
        -- Generate each manager function
        initResult : ExprResult
        initResult =
            generateExpr ctx managerInfo.init

        onEffectsResult : ExprResult
        onEffectsResult =
            generateExpr initResult.ctx managerInfo.onEffects

        onSelfMsgResult : ExprResult
        onSelfMsgResult =
            generateExpr onEffectsResult.ctx managerInfo.onSelfMsg

        -- Generate optional cmdMap and subMap
        ( cmdMapOps, cmdMapVar, ctx1 ) =
            case managerInfo.cmdMap of
                Just cmdMapExpr ->
                    let
                        result =
                            generateExpr onSelfMsgResult.ctx cmdMapExpr
                    in
                    ( result.ops, result.resultVar, result.ctx )

                Nothing ->
                    let
                        ( nullVar, c ) =
                            freshVar onSelfMsgResult.ctx
                    in
                    ( [ ecoConstruct c nullVar 0 0 0 [] ], nullVar, c )

        ( subMapOps, subMapVar, ctx2 ) =
            case managerInfo.subMap of
                Just subMapExpr ->
                    let
                        result =
                            generateExpr ctx1 subMapExpr
                    in
                    ( result.ops, result.resultVar, result.ctx )

                Nothing ->
                    let
                        ( nullVar, c ) =
                            freshVar ctx1
                    in
                    ( [ ecoConstruct c nullVar 0 0 0 [] ], nullVar, c )

        -- Create the manager record
        ( resultVar, ctx3 ) =
            freshVar ctx2

        managerOp : MlirOp
        managerOp =
            ecoConstruct ctx3
                resultVar
                0
                5
                0
                [ ( initResult.resultVar, ecoValue )
                , ( onEffectsResult.resultVar, ecoValue )
                , ( onSelfMsgResult.resultVar, ecoValue )
                , ( cmdMapVar, ecoValue )
                , ( subMapVar, ecoValue )
                ]

        returnOp : MlirOp
        returnOp =
            ecoReturn ctx3 resultVar ecoValue

        allOps : List MlirOp
        allOps =
            initResult.ops
                ++ onEffectsResult.ops
                ++ onSelfMsgResult.ops
                ++ cmdMapOps
                ++ subMapOps
                ++ [ managerOp ]

        region : MlirRegion
        region =
            mkRegion [] allOps returnOp
    in
    funcFunc ctx funcName [] (monoTypeToMlir monoType) region



-- GENERATE CYCLE


generateCycle : Context -> String -> List ( Name.Name, Mono.MonoExpr ) -> Mono.MonoType -> ( MlirOp, Context )
generateCycle ctx funcName definitions monoType =
    -- Generate mutually recursive definitions
    -- For now, generate a thunk that creates a record of all the cycle definitions
    let
        -- Generate each definition in the cycle
        ( defOps, defVars, finalCtx ) =
            List.foldl
                (\( name, expr ) ( accOps, accVars, accCtx ) ->
                    let
                        result : ExprResult
                        result =
                            generateExpr accCtx expr
                    in
                    ( accOps ++ result.ops, accVars ++ [ result.resultVar ], result.ctx )
                )
                ( [], [], ctx )
                definitions

        -- Create a record containing all the cycle definitions
        ( resultVar, ctx1 ) =
            freshVar finalCtx

        arity : Int
        arity =
            List.length definitions

        -- All definition results are boxed values
        defVarPairs : List ( String, MlirType )
        defVarPairs =
            List.map (\v -> ( v, ecoValue )) defVars

        cycleOp : MlirOp
        cycleOp =
            ecoConstruct ctx1 resultVar 0 arity 0 defVarPairs

        returnOp : MlirOp
        returnOp =
            ecoReturn ctx1 resultVar ecoValue

        region : MlirRegion
        region =
            mkRegion [] (defOps ++ [ cycleOp ]) returnOp
    in
    ( funcFunc ctx funcName [] (monoTypeToMlir monoType) region, ctx1 )



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

        Mono.MonoTupleAccess tuple index isUnboxed _ ->
            generateTupleAccess ctx tuple index isUnboxed

        Mono.MonoCustomCreate ctorName tag fields layout _ ->
            generateCustomCreate ctx ctorName tag fields layout

        Mono.MonoUnit ->
            generateUnit ctx

        Mono.MonoAccessor _ fieldName _ ->
            generateAccessor ctx fieldName

        Mono.MonoVarDebug _ name home maybeName monoType ->
            generateVarDebug ctx name home maybeName monoType

        Mono.MonoVarCycle _ home name monoType ->
            generateVarCycle ctx home name monoType

        Mono.MonoShader _ shaderInfo _ ->
            generateShader ctx shaderInfo

        Mono.MonoPolyGlobal _ (TOpt.Global (IO.Canonical _ moduleName) name) _ ->
            crash ("MLIR codegen: unresolved MonoPolyGlobal for " ++ moduleName ++ "." ++ name ++ " - should have been instantiated at call site")



-- LITERAL GENERATION


generateLiteral : Context -> Mono.Literal -> ExprResult
generateLiteral ctx lit =
    case lit of
        Mono.LBool value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx
            in
            { ops = [ arithConstantBool ctx1 var value ]
            , resultVar = var
            , ctx = ctx1
            }

        Mono.LInt value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx
            in
            { ops = [ arithConstantInt ctx1 var value ]
            , resultVar = var
            , ctx = ctx1
            }

        Mono.LFloat value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx
            in
            { ops = [ arithConstantFloat ctx1 var value ]
            , resultVar = var
            , ctx = ctx1
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
            in
            { ops = [ arithConstantChar ctx1 var codepoint ]
            , resultVar = var
            , ctx = ctx1
            }

        Mono.LStr value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx
            in
            { ops = [ ecoStringLiteral ctx1 var value ]
            , resultVar = var
            , ctx = ctx1
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
            -- Function-typed global: create a closure (papCreate) with no captures
            -- The arity is the number of function arguments
            let
                arity : Int
                arity =
                    countTotalArity monoType

                papOp : MlirOp
                papOp =
                    mlirOp "eco.papCreate" ctx1
                        |> withResult var ecoValue
                        |> withAttr "function" (SymbolRefAttr funcName)
                        |> withAttr "arity" (IntAttr arity)
                        |> withAttr "num_captured" (IntAttr 0)
                        |> build
            in
            { ops = [ papOp ]
            , resultVar = var
            , ctx = ctx1
            }

        _ ->
            -- Non-function type: call the function directly (e.g., zero-arg constructors)
            { ops = [ ecoCallNamed ctx1 var funcName [] (monoTypeToMlir monoType) ]
            , resultVar = var
            , ctx = ctx1
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
            -- Emit constant directly
            { ops = [ arithConstantFloat ctx1 var value ]
            , resultVar = var
            , ctx = ctx1
            }

        Just _ ->
            -- This is a function-type intrinsic used as a value
            -- Fall back to kernel call for now (wrapper generation could be added later)
            let
                kernelName : String
                kernelName =
                    "Elm_Kernel_" ++ home ++ "_" ++ name
            in
            { ops = [ ecoCallNamed ctx1 var kernelName [] (monoTypeToMlir monoType) ]
            , resultVar = var
            , ctx = ctx1
            }

        Nothing ->
            -- Not an intrinsic - call kernel function
            let
                kernelName : String
                kernelName =
                    "Elm_Kernel_" ++ home ++ "_" ++ name
            in
            { ops = [ ecoCallNamed ctx1 var kernelName [] (monoTypeToMlir monoType) ]
            , resultVar = var
            , ctx = ctx1
            }


generateVarDebug : Context -> Name.Name -> IO.Canonical -> Maybe Name.Name -> Mono.MonoType -> ExprResult
generateVarDebug ctx name home maybeName monoType =
    -- Debug.log, Debug.todo, Debug.toString, etc.
    let
        ( var, ctx1 ) =
            freshVar ctx

        debugName : String
        debugName =
            case maybeName of
                Just n ->
                    "Elm_Debug_" ++ name ++ "_" ++ n

                Nothing ->
                    "Elm_Debug_" ++ name

        callOp : MlirOp
        callOp =
            ecoCallNamed ctx1 var debugName [] (monoTypeToMlir monoType)
    in
    { ops = [ callOp ]
    , resultVar = var
    , ctx = ctx1
    }


generateVarCycle : Context -> IO.Canonical -> Name.Name -> Mono.MonoType -> ExprResult
generateVarCycle ctx home name monoType =
    -- Reference to a variable in a mutually recursive cycle
    let
        ( var, ctx1 ) =
            freshVar ctx

        cycleName : String
        cycleName =
            canonicalToMLIRName home ++ "_$cycle_" ++ name

        callOp : MlirOp
        callOp =
            ecoCallNamed ctx1 var cycleName [] (monoTypeToMlir monoType)
    in
    { ops = [ callOp ]
    , resultVar = var
    , ctx = ctx1
    }


generateShader : Context -> Mono.ShaderInfo -> ExprResult
generateShader ctx shaderInfo =
    -- WebGL shader - generate a placeholder since we don't support WebGL natively
    let
        ( var, ctx1 ) =
            freshVar ctx

        -- Create a shader object that contains the source and type info
        -- For now, just create a record with the shader source as a string
        ( srcVar, ctx2 ) =
            freshVar ctx1

        srcOp : MlirOp
        srcOp =
            ecoStringLiteral ctx2 srcVar shaderInfo.src

        -- Create a shader struct with the source
        shaderOp : MlirOp
        shaderOp =
            mlirOp "eco.shader" ctx2
                |> withOperands [ ( srcVar, ecoValue ) ]
                |> withResult var ecoValue
                |> withAttr "source" (StringAttr shaderInfo.src)
                |> build
    in
    { ops = [ srcOp, shaderOp ]
    , resultVar = var
    , ctx = ctx2
    }



-- LIST GENERATION


generateList : Context -> List Mono.MonoExpr -> ExprResult
generateList ctx items =
    case items of
        [] ->
            -- Empty list: Nil tag 0
            let
                ( var, ctx1 ) =
                    freshVar ctx
            in
            { ops = [ ecoConstruct ctx1 var 0 0 0 [] ]
            , resultVar = var
            , ctx = ctx1
            }

        _ ->
            -- Build list from right to left
            let
                ( nilVar, ctx1 ) =
                    freshVar ctx

                nilOp : MlirOp
                nilOp =
                    ecoConstruct ctx1 nilVar 0 0 0 []

                -- Fold from right
                ( consOps, finalVar, finalCtx ) =
                    List.foldr
                        (\item ( accOps, tailVar, accCtx ) ->
                            let
                                itemResult : ExprResult
                                itemResult =
                                    generateExpr accCtx item

                                ( consVar, ctx2 ) =
                                    freshVar itemResult.ctx

                                -- Cons tag 1, size 2 (head and tail are both boxed values)
                                consOp : MlirOp
                                consOp =
                                    ecoConstruct ctx2 consVar 1 2 0 [ ( itemResult.resultVar, ecoValue ), ( tailVar, ecoValue ) ]
                            in
                            ( accOps ++ itemResult.ops ++ [ consOp ], consVar, ctx2 )
                        )
                        ( [], nilVar, ctx1 )
                        items
            in
            { ops = nilOp :: consOps
            , resultVar = finalVar
            , ctx = finalCtx
            }



-- CLOSURE GENERATION


generateClosure : Context -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateClosure ctx closureInfo body monoType =
    -- Generate captured values and create a PAP
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

        -- PAP boundary: ensure boxed captures
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

        -- Total arity = captures + params (the underlying function takes both)
        arity : Int
        arity =
            numCaptured + List.length closureInfo.params

        -- Captures are all boxed values
        captureVarPairs : List ( String, MlirType )
        captureVarPairs =
            List.map (\v -> ( v, ecoValue )) boxedCaptureVars

        -- Create a papCreate op
        papOp : MlirOp
        papOp =
            mlirOp "eco.papCreate" ctx2
                |> withOperands captureVarPairs
                |> withResult resultVar ecoValue
                |> withAttr "function" (SymbolRefAttr (lambdaIdToString closureInfo.lambdaId))
                |> withAttr "arity" (IntAttr arity)
                |> withAttr "num_captured" (IntAttr numCaptured)
                |> build

        -- Register this lambda for later emission as a func.func
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

        ctx3 : Context
        ctx3 =
            { ctx2 | pendingLambdas = pendingLambda :: ctx2.pendingLambdas }
    in
    { ops = captureOps ++ boxOps ++ [ papOp ]
    , resultVar = resultVar
    , ctx = ctx3
    }


lambdaIdToString : Mono.LambdaId -> String
lambdaIdToString lambdaId =
    case lambdaId of
        Mono.NamedFunction (Mono.Global home name) ->
            canonicalToMLIRName home ++ "_" ++ sanitizeName name

        Mono.AnonymousLambda home uid _ ->
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

            boxOp : MlirOp
            boxOp =
                mlirOp "eco.box" ctx1
                    |> withOperands [ ( var, mlirTy ) ]
                    |> withResult boxedVar ecoValue
                    |> build
        in
        ( [ boxOp ], boxedVar, ctx1 )


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
            -- Direct call to known specialization
            let
                -- Assert monomorphization invariant: call site types must match function signature
                ( argsOps, argVars, ctx1 ) =
                    generateExprList ctx args

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                -- Use unboxed primitives when the Mono types are primitive
                argVarPairs : List ( String, MlirType )
                argVarPairs =
                    argVarPairsFromExprs args argVars

                funcName : String
                funcName =
                    specIdToFuncName ctx.registry specId
            in
            { ops = argsOps ++ [ ecoCallNamed ctx2 resultVar funcName argVarPairs (monoTypeToMlir resultType) ]
            , resultVar = resultVar
            , ctx = ctx2
            }

        Mono.MonoVarKernel _ home name _ ->
            -- Direct call to kernel function - check for intrinsic first
            let
                ( argsOps, argVars, ctx1 ) =
                    generateExprList ctx args

                -- Get argument types for intrinsic lookup
                argTypes : List Mono.MonoType
                argTypes =
                    List.map Mono.typeOf args
            in
            -- Special case: logBase - expand inline as log(x) / log(base)
            case ( home, name, argVars ) of
                ( "Basics", "logBase", [ baseVar, xVar ] ) ->
                    let
                        ( logXVar, ctx2 ) =
                            freshVar ctx1

                        ( logBaseVar, ctx3 ) =
                            freshVar ctx2

                        ( resultVar, ctx4 ) =
                            freshVar ctx3

                        logXOp =
                            ecoUnaryOp ctx2 "eco.float.log" logXVar ( xVar, F64 ) F64

                        logBaseOp =
                            ecoUnaryOp ctx3 "eco.float.log" logBaseVar ( baseVar, F64 ) F64

                        divOp =
                            ecoBinaryOp ctx4 "eco.float.div" resultVar ( logXVar, F64 ) ( logBaseVar, F64 ) F64
                    in
                    { ops = argsOps ++ [ logXOp, logBaseOp, divOp ]
                    , resultVar = resultVar
                    , ctx = ctx4
                    }

                _ ->
                    -- Check for intrinsic
                    case kernelIntrinsic home name argTypes resultType of
                        Just intrinsic ->
                            -- Emit intrinsic op with UNBOXED types (no boxing needed!)
                            let
                                ( resultVar, ctx2 ) =
                                    freshVar ctx1

                                intrinsicOp =
                                    generateIntrinsicOp ctx2 intrinsic resultVar argVars
                            in
                            { ops = argsOps ++ [ intrinsicOp ]
                            , resultVar = resultVar
                            , ctx = ctx2
                            }

                        Nothing ->
                            -- Fall back to kernel call (existing behavior)
                            let
                                argsWithTypes : List ( String, Mono.MonoType )
                                argsWithTypes =
                                    List.map2 (\expr var -> ( var, Mono.typeOf expr )) args argVars

                                ( boxOps, boxedVars, ctx1b ) =
                                    boxArgsIfNeeded ctx1 argsWithTypes

                                ( resultVar, ctx2 ) =
                                    freshVar ctx1b

                                -- All function arguments are boxed values
                                argVarPairs : List ( String, MlirType )
                                argVarPairs =
                                    List.map (\v -> ( v, ecoValue )) boxedVars

                                kernelName : String
                                kernelName =
                                    "Elm_Kernel_" ++ home ++ "_" ++ name
                            in
                            { ops = argsOps ++ boxOps ++ [ ecoCallNamed ctx2 resultVar kernelName argVarPairs (monoTypeToMlir resultType) ]
                            , resultVar = resultVar
                            , ctx = ctx2
                            }

        Mono.MonoVarLocal name _ ->
            -- Call through local variable (closure)
            let
                ( argsOps, argVars, ctx1 ) =
                    generateExprList ctx args

                -- PAP boundary: ensure boxed arguments
                argsWithTypes : List ( String, Mono.MonoType )
                argsWithTypes =
                    List.map2 (\expr var -> ( var, Mono.typeOf expr )) args argVars

                ( boxOps, boxedVars, ctx1b ) =
                    boxArgsIfNeeded ctx1 argsWithTypes

                ( resultVar, ctx2 ) =
                    freshVar ctx1b

                -- Closure and all args are boxed values
                allOperandPairs : List ( String, MlirType )
                allOperandPairs =
                    ( "%" ++ name, ecoValue ) :: List.map (\v -> ( v, ecoValue )) boxedVars

                -- remaining_arity is the arity of the result type (how many more args needed)
                remainingArity : Int
                remainingArity =
                    functionArity resultType

                papExtendOp : MlirOp
                papExtendOp =
                    mlirOp "eco.papExtend" ctx2
                        |> withOperands allOperandPairs
                        |> withResult resultVar (monoTypeToMlir resultType)
                        |> withAttr "remaining_arity" (IntAttr remainingArity)
                        |> build
            in
            { ops = argsOps ++ boxOps ++ [ papExtendOp ]
            , resultVar = resultVar
            , ctx = ctx2
            }

        _ ->
            -- General case: evaluate function then call
            let
                funcResult : ExprResult
                funcResult =
                    generateExpr ctx func

                ( argsOps, argVars, ctx1 ) =
                    generateExprList funcResult.ctx args

                -- PAP boundary: ensure boxed arguments
                argsWithTypes : List ( String, Mono.MonoType )
                argsWithTypes =
                    List.map2 (\expr var -> ( var, Mono.typeOf expr )) args argVars

                ( boxOps, boxedVars, ctx1b ) =
                    boxArgsIfNeeded ctx1 argsWithTypes

                ( resultVar, ctx2 ) =
                    freshVar ctx1b

                -- Closure and all args are boxed values
                allOperandPairs : List ( String, MlirType )
                allOperandPairs =
                    ( funcResult.resultVar, ecoValue ) :: List.map (\v -> ( v, ecoValue )) boxedVars

                -- remaining_arity is the arity of the result type (how many more args needed)
                remainingArity : Int
                remainingArity =
                    functionArity resultType

                papExtendOp : MlirOp
                papExtendOp =
                    mlirOp "eco.papExtend" ctx2
                        |> withOperands allOperandPairs
                        |> withResult resultVar (monoTypeToMlir resultType)
                        |> withAttr "remaining_arity" (IntAttr remainingArity)
                        |> build
            in
            { ops = funcResult.ops ++ argsOps ++ boxOps ++ [ papExtendOp ]
            , resultVar = resultVar
            , ctx = ctx2
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

        -- Use actual argument types
        argVarPairs : List ( String, MlirType )
        argVarPairs =
            List.map2
                (\( _, expr ) v -> ( v, monoTypeToMlir (Mono.typeOf expr) ))
                args
                argVars

        jumpOp : MlirOp
        jumpOp =
            mlirOp "eco.jump" ctx1
                |> withOperands argVarPairs
                |> withAttr "target" (StringAttr name)
                |> asTerminator
                |> build

        -- Need a placeholder result since jump is a terminator
        ( resultVar, ctx2 ) =
            freshVar ctx1
    in
    { ops = argsOps ++ [ jumpOp, ecoConstruct ctx2 resultVar 0 0 0 [] ]
    , resultVar = resultVar
    , ctx = ctx2
    }



-- IF GENERATION


generateIf : Context -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> Mono.MonoExpr -> ExprResult
generateIf ctx branches final =
    case branches of
        [] ->
            generateExpr ctx final

        ( cond, thenBranch ) :: restBranches ->
            let
                condResult : ExprResult
                condResult =
                    generateExpr ctx cond

                thenResult : ExprResult
                thenResult =
                    generateExpr condResult.ctx thenBranch

                elseResult : ExprResult
                elseResult =
                    generateIf thenResult.ctx restBranches final

                -- TODO: Proper scf.if implementation
            in
            { ops = condResult.ops ++ thenResult.ops ++ elseResult.ops
            , resultVar = elseResult.resultVar
            , ctx = elseResult.ctx
            }



-- LET GENERATION


generateLet : Context -> Mono.MonoDef -> Mono.MonoExpr -> ExprResult
generateLet ctx def body =
    case def of
        Mono.MonoDef _ name expr _ ->
            let
                exprResult : ExprResult
                exprResult =
                    generateExpr ctx expr

                -- Bind the name (the expression result is a boxed value)
                aliasOp : MlirOp
                aliasOp =
                    ecoConstruct exprResult.ctx ("%" ++ name) 0 1 0 [ ( exprResult.resultVar, ecoValue ) ]

                bodyResult : ExprResult
                bodyResult =
                    generateExpr exprResult.ctx body
            in
            { ops = exprResult.ops ++ [ aliasOp ] ++ bodyResult.ops
            , resultVar = bodyResult.resultVar
            , ctx = bodyResult.ctx
            }

        Mono.MonoTailDef _ _ _ _ _ ->
            -- TODO: Proper joinpoint handling
            generateExpr ctx body



-- DESTRUCT GENERATION


generateDestruct : Context -> Mono.MonoDestructor -> Mono.MonoExpr -> ExprResult
generateDestruct ctx (Mono.MonoDestructor name path _) body =
    let
        ( pathOps, pathVar, ctx1 ) =
            generateMonoPath ctx path

        -- The path result is a boxed value
        aliasOp : MlirOp
        aliasOp =
            ecoConstruct ctx1 ("%" ++ name) 0 1 0 [ ( pathVar, ecoValue ) ]

        bodyResult : ExprResult
        bodyResult =
            generateExpr ctx1 body
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
            in
            ( subOps ++ [ ecoProject ctx2 resultVar index False subVar ecoValue ]
            , resultVar
            , ctx2
            )

        Mono.MonoField _ index subPath ->
            let
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath

                ( resultVar, ctx2 ) =
                    freshVar ctx1
            in
            ( subOps ++ [ ecoProject ctx2 resultVar index False subVar ecoValue ]
            , resultVar
            , ctx2
            )

        Mono.MonoUnbox subPath ->
            generateMonoPath ctx subPath

        Mono.MonoArrayIndex index subPath ->
            let
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                -- Array access operation (operand is boxed value)
                arrayAccessOp : MlirOp
                arrayAccessOp =
                    mlirOp "eco.array_get" ctx2
                        |> withOperands [ ( subVar, ecoValue ) ]
                        |> withResult resultVar ecoValue
                        |> withAttr "index" (IntAttr index)
                        |> build
            in
            ( subOps ++ [ arrayAccessOp ]
            , resultVar
            , ctx2
            )



-- CASE GENERATION


generateCase : Context -> Name.Name -> Name.Name -> Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> ExprResult
generateCase ctx scrutinee1 scrutinee2 decider jumps =
    -- TODO: Proper decision tree compilation
    let
        ( resultVar, ctx1 ) =
            freshVar ctx
    in
    { ops = [ ecoConstruct ctx1 resultVar 0 0 0 [] ]
    , resultVar = resultVar
    , ctx = ctx1
    }



-- RECORD GENERATION


generateRecordCreate : Context -> List Mono.MonoExpr -> Mono.RecordLayout -> ExprResult
generateRecordCreate ctx fields layout =
    let
        ( fieldsOps, fieldVars, ctx1 ) =
            generateExprList ctx fields

        ( resultVar, ctx2 ) =
            freshVar ctx1

        -- Use correct types for unboxed fields
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
    in
    { ops = fieldsOps ++ [ ecoConstruct ctx2 resultVar 0 layout.fieldCount layout.unboxedBitmap fieldVarPairs ]
    , resultVar = resultVar
    , ctx = ctx2
    }


generateRecordAccess : Context -> Mono.MonoExpr -> Name.Name -> Int -> Bool -> ExprResult
generateRecordAccess ctx record fieldName index isUnboxed =
    let
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record

        ( resultVar, ctx1 ) =
            freshVar recordResult.ctx
    in
    { ops = recordResult.ops ++ [ ecoProject ctx1 resultVar index isUnboxed recordResult.resultVar ecoValue ]
    , resultVar = resultVar
    , ctx = ctx1
    }


generateRecordUpdate : Context -> Mono.MonoExpr -> List ( Int, Mono.MonoExpr ) -> Mono.RecordLayout -> ExprResult
generateRecordUpdate ctx record updates layout =
    -- TODO: Proper record update implementation
    let
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record

        ( resultVar, ctx1 ) =
            freshVar recordResult.ctx
    in
    { ops = recordResult.ops ++ [ ecoConstruct ctx1 resultVar 0 1 0 [ ( recordResult.resultVar, ecoValue ) ] ]
    , resultVar = resultVar
    , ctx = ctx1
    }



-- TUPLE GENERATION


generateTupleCreate : Context -> List Mono.MonoExpr -> Mono.TupleLayout -> ExprResult
generateTupleCreate ctx elements layout =
    let
        ( elemOps, elemVars, ctx1 ) =
            generateExprList ctx elements

        ( resultVar, ctx2 ) =
            freshVar ctx1

        -- Use correct types for unboxed elements
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
    in
    { ops = elemOps ++ [ ecoConstruct ctx2 resultVar 0 layout.arity layout.unboxedBitmap elemVarPairs ]
    , resultVar = resultVar
    , ctx = ctx2
    }


generateTupleAccess : Context -> Mono.MonoExpr -> Int -> Bool -> ExprResult
generateTupleAccess ctx tuple index isUnboxed =
    let
        tupleResult : ExprResult
        tupleResult =
            generateExpr ctx tuple

        ( resultVar, ctx1 ) =
            freshVar tupleResult.ctx
    in
    { ops = tupleResult.ops ++ [ ecoProject ctx1 resultVar index isUnboxed tupleResult.resultVar ecoValue ]
    , resultVar = resultVar
    , ctx = ctx1
    }



-- CUSTOM TYPE GENERATION


generateCustomCreate : Context -> Name.Name -> Int -> List Mono.MonoExpr -> Mono.CtorLayout -> ExprResult
generateCustomCreate ctx ctorName tag fields layout =
    let
        ( fieldsOps, fieldVars, ctx1 ) =
            generateExprList ctx fields

        ( resultVar, ctx2 ) =
            freshVar ctx1

        arity : Int
        arity =
            List.length fields

        -- Use correct types for unboxed fields
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
    in
    { ops = fieldsOps ++ [ ecoConstruct ctx2 resultVar tag arity layout.unboxedBitmap fieldVarPairs ]
    , resultVar = resultVar
    , ctx = ctx2
    }



-- UNIT GENERATION


generateUnit : Context -> ExprResult
generateUnit ctx =
    let
        ( var, ctx1 ) =
            freshVar ctx
    in
    { ops = [ ecoConstruct ctx1 var 0 0 0 [] ]
    , resultVar = var
    , ctx = ctx1
    }



-- ACCESSOR GENERATION


generateAccessor : Context -> Name.Name -> ExprResult
generateAccessor ctx fieldName =
    let
        ( var, ctx1 ) =
            freshVar ctx

        papOp : MlirOp
        papOp =
            mlirOp "eco.papCreate" ctx1
                |> withResult var ecoValue
                |> withAttr "function" (SymbolRefAttr ("accessor_" ++ fieldName))
                |> withAttr "arity" (IntAttr 1)
                |> withAttr "num_captured" (IntAttr 0)
                |> build
    in
    { ops = [ papOp ]
    , resultVar = var
    , ctx = ctx1
    }



-- HELPERS


canonicalToMLIRName : IO.Canonical -> String
canonicalToMLIRName (IO.Canonical _ moduleName) =
    String.replace "." "_" moduleName


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
