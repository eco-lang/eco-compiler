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
import Compiler.Optimize.Typed.DecisionTree as DT
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



-- ====== BACKEND ======


{-| The MLIR backend that generates MLIR code from fully monomorphized IR with all polymorphism resolved.
-}
backend : CodeGen.MonoCodeGen
backend =
    { generate =
        \config ->
            generateModule config.mode config.graph |> CodeGen.TextOutput
    }



-- ====== ECO DIALECT TYPES ======


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


{-| eco.char - unboxed character (i16 unicode codepoint, BMP only)
-}
ecoChar : MlirType
ecoChar =
    I16



-- ====== CONVERT MONOTYPE TO MLIR TYPE ======


monoTypeToMlir : Mono.MonoType -> MlirType
monoTypeToMlir monoType =
    case monoType of
        Mono.MInt ->
            ecoInt

        Mono.MFloat ->
            ecoFloat

        Mono.MBool ->
            I1

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

        Mono.MVar _ constraint_ ->
            case constraint_ of
                Mono.CNumber ->
                    I64

                Mono.CEcoValue ->
                    ecoValue


{-| Check if a MonoType is a function type.
-}
isFunctionType : Mono.MonoType -> Bool
isFunctionType monoType =
    case monoType of
        Mono.MFunction _ _ ->
            True

        _ ->
            False


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



-- ====== CONTEXT ======


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

        "Utils" ->
            -- Utils.compare and Utils.equal work with any comparable/equatable type
            -- They need boxed !eco.value arguments
            name == "compare" || name == "equal"

        "Basics" ->
            -- min, max, compare work with any comparable type
            -- These need boxed !eco.value arguments when called as kernel functions
            -- Numeric operations (add, sub, mul, etc.) are ALSO polymorphic kernels
            -- because the C++ implementations (Elm_Kernel_Basics_add, etc.) expect
            -- boxed eco.value pointers, not raw i64 values. When called as kernels
            -- (not via intrinsics), we must box the arguments.
            name
                == "min"
                || name
                == "max"
                || name
                == "compare"
                || name
                == "add"
                || name
                == "sub"
                || name
                == "mul"
                || name
                == "idiv"
                || name
                == "modBy"
                || name
                == "remainderBy"
                || name
                == "negate"
                || name
                == "abs"
                || name
                == "pow"
                || name
                == "fdiv"

        _ ->
            False


{-| Get the actual C ABI signature for known kernel functions.
This is used when the Elm type is polymorphic (MonoValue) but the kernel
expects concrete types. Returns Nothing for polymorphic kernels or
unknown kernels.
-}
actualKernelAbi : String -> String -> Maybe FuncSignature
actualKernelAbi home name =
    case home of
        "Basics" ->
            -- NOTE: Polymorphic operations (add, sub, mul, negate, abs) should NOT
            -- be listed here - they should use the monomorphized types from the Elm
            -- type system to determine whether they're Int or Float operations.
            -- Only list operations that are always a specific type.
            case name of
                -- fdiv is always Float (integer division uses different operators)
                "fdiv" ->
                    Just { paramTypes = [ Mono.MFloat, Mono.MFloat ], returnType = Mono.MFloat }

                -- Math functions are always Float
                "sqrt" ->
                    Just { paramTypes = [ Mono.MFloat ], returnType = Mono.MFloat }

                "ceiling" ->
                    Just { paramTypes = [ Mono.MFloat ], returnType = Mono.MInt }

                "floor" ->
                    Just { paramTypes = [ Mono.MFloat ], returnType = Mono.MInt }

                "round" ->
                    Just { paramTypes = [ Mono.MFloat ], returnType = Mono.MInt }

                "truncate" ->
                    Just { paramTypes = [ Mono.MFloat ], returnType = Mono.MInt }

                "toFloat" ->
                    Just { paramTypes = [ Mono.MInt ], returnType = Mono.MFloat }

                "sin" ->
                    Just { paramTypes = [ Mono.MFloat ], returnType = Mono.MFloat }

                "cos" ->
                    Just { paramTypes = [ Mono.MFloat ], returnType = Mono.MFloat }

                "tan" ->
                    Just { paramTypes = [ Mono.MFloat ], returnType = Mono.MFloat }

                "asin" ->
                    Just { paramTypes = [ Mono.MFloat ], returnType = Mono.MFloat }

                "acos" ->
                    Just { paramTypes = [ Mono.MFloat ], returnType = Mono.MFloat }

                "atan" ->
                    Just { paramTypes = [ Mono.MFloat ], returnType = Mono.MFloat }

                "atan2" ->
                    Just { paramTypes = [ Mono.MFloat, Mono.MFloat ], returnType = Mono.MFloat }

                "pow" ->
                    Just { paramTypes = [ Mono.MFloat, Mono.MFloat ], returnType = Mono.MFloat }

                "e" ->
                    Just { paramTypes = [], returnType = Mono.MFloat }

                "pi" ->
                    Just { paramTypes = [], returnType = Mono.MFloat }

                "modBy" ->
                    Just { paramTypes = [ Mono.MInt, Mono.MInt ], returnType = Mono.MInt }

                "remainderBy" ->
                    Just { paramTypes = [ Mono.MInt, Mono.MInt ], returnType = Mono.MInt }

                "not" ->
                    Just { paramTypes = [ Mono.MBool ], returnType = Mono.MBool }

                "xor" ->
                    Just { paramTypes = [ Mono.MBool, Mono.MBool ], returnType = Mono.MBool }

                _ ->
                    Nothing

        _ ->
            Nothing


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
    , varMappings : Dict String ( String, MlirType ) -- Let-bound name -> (SSA variable name, MLIR type)
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
Returns both the SSA variable name and its MLIR type.
-}
lookupVar : Context -> String -> ( String, MlirType )
lookupVar ctx name =
    case Dict.get name ctx.varMappings of
        Just ( ssaVar, mlirTy ) ->
            ( ssaVar, mlirTy )

        Nothing ->
            -- Function parameters default to !eco.value
            ( "%" ++ name, ecoValue )


{-| Add a variable mapping from a let-bound name to its SSA variable and type.
-}
addVarMapping : String -> String -> MlirType -> Context -> Context
addVarMapping name ssaVar mlirTy ctx =
    { ctx | varMappings = Dict.insert name ( ssaVar, mlirTy ) ctx.varMappings }



-- ====== SIGNATURE EXTRACTION ======


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



-- ====== EXPRESSION RESULT ======


type alias ExprResult =
    { ops : List MlirOp
    , resultVar : String
    , resultType : MlirType
    , ctx : Context
    }


emptyResult : Context -> String -> MlirType -> ExprResult
emptyResult ctx var ty =
    { ops = [], resultVar = var, resultType = ty, ctx = ctx }



-- ====== INTRINSIC DEFINITIONS ======
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


{-| Get the MLIR result type for an intrinsic operation.
-}
intrinsicResultMlirType : Intrinsic -> MlirType
intrinsicResultMlirType intrinsic =
    case intrinsic of
        UnaryInt _ ->
            ecoInt

        BinaryInt _ ->
            ecoInt

        UnaryFloat _ ->
            ecoFloat

        BinaryFloat _ ->
            ecoFloat

        UnaryBool _ ->
            I1

        BinaryBool _ ->
            I1

        IntToFloat ->
            ecoFloat

        FloatToInt _ ->
            ecoInt

        IntComparison _ ->
            I1

        FloatComparison _ ->
            I1

        FloatClassify _ ->
            I1

        ConstantFloat _ ->
            ecoFloat


{-| Get the expected operand types for an intrinsic operation.
-}
intrinsicOperandTypes : Intrinsic -> List MlirType
intrinsicOperandTypes intrinsic =
    case intrinsic of
        UnaryInt _ ->
            [ I64 ]

        BinaryInt _ ->
            [ I64, I64 ]

        UnaryFloat _ ->
            [ F64 ]

        BinaryFloat _ ->
            [ F64, F64 ]

        UnaryBool _ ->
            [ I1 ]

        BinaryBool _ ->
            [ I1, I1 ]

        IntToFloat ->
            [ I64 ]

        FloatToInt _ ->
            [ F64 ]

        IntComparison _ ->
            [ I64, I64 ]

        FloatComparison _ ->
            [ F64, F64 ]

        FloatClassify _ ->
            [ F64 ]

        ConstantFloat _ ->
            []


{-| Unbox arguments to match the expected operand types for an intrinsic.
If an argument has !eco.value type but the intrinsic expects a primitive type,
an unbox operation is inserted.
-}
unboxArgsForIntrinsic : Context -> List ( String, MlirType ) -> Intrinsic -> ( List MlirOp, List String, Context )
unboxArgsForIntrinsic ctx argsWithTypes intrinsic =
    let
        expectedTypes =
            intrinsicOperandTypes intrinsic
    in
    List.foldl
        (\( ( var, actualType ), expectedType ) ( opsAcc, varsAcc, ctxAcc ) ->
            if isEcoValueType actualType && not (isEcoValueType expectedType) then
                -- Need to unbox: actual is !eco.value, expected is primitive
                let
                    ( unboxOps, unboxedVar, newCtx ) =
                        unboxToType ctxAcc var expectedType
                in
                ( opsAcc ++ unboxOps, varsAcc ++ [ unboxedVar ], newCtx )

            else
                -- No unboxing needed
                ( opsAcc, varsAcc ++ [ var ], ctxAcc )
        )
        ( [], [], ctx )
        (List.map2 Tuple.pair argsWithTypes expectedTypes)


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



-- ====== GENERATE MODULE ======


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



-- ====== LAMBDA PROCESSING ======


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
        -- All parameters use !eco.value in the signature (boxed calling convention)
        captureArgPairs : List ( String, MlirType )
        captureArgPairs =
            List.map (\( name, _ ) -> ( "%" ++ name, ecoValue )) lambda.captures

        -- Use !eco.value for all params in signature - callers pass boxed values
        paramArgPairs : List ( String, MlirType )
        paramArgPairs =
            List.map (\( name, _ ) -> ( "%" ++ name, ecoValue )) lambda.params

        allArgPairs : List ( String, MlirType )
        allArgPairs =
            captureArgPairs ++ paramArgPairs

        -- Generate unbox operations for parameters that need primitive types
        -- and build the varMappings with the unboxed variable names
        ( unboxOps, varMappingsWithParams, ctxAfterUnbox ) =
            List.foldl
                (\( name, ty ) ( opsAcc, mappingsAcc, ctxAcc ) ->
                    let
                        paramMlirType =
                            monoTypeToMlir ty

                        boxedVarName =
                            "%" ++ name
                    in
                    if isEcoValueType paramMlirType then
                        -- Parameter is already !eco.value, no unboxing needed
                        ( opsAcc
                        , Dict.insert name ( boxedVarName, ecoValue ) mappingsAcc
                        , ctxAcc
                        )

                    else
                        -- Need to unbox the parameter
                        let
                            ( unboxedVar, ctxU1 ) =
                                freshVar ctxAcc

                            attrs =
                                Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr ecoValue ])

                            ( ctxU2, unboxOp ) =
                                mlirOp ctxU1 "eco.unbox"
                                    |> opBuilder.withOperands [ boxedVarName ]
                                    |> opBuilder.withResults [ ( unboxedVar, paramMlirType ) ]
                                    |> opBuilder.withAttrs attrs
                                    |> opBuilder.build
                        in
                        ( opsAcc ++ [ unboxOp ]
                        , Dict.insert name ( unboxedVar, paramMlirType ) mappingsAcc
                        , ctxU2
                        )
                )
                ( []
                , List.foldl
                    (\( name, _ ) acc -> Dict.insert name ( "%" ++ name, ecoValue ) acc)
                    Dict.empty
                    lambda.captures
                , { ctx | nextVar = List.length allArgPairs }
                )
                lambda.params

        ctxWithArgs : Context
        ctxWithArgs =
            { ctxAfterUnbox | varMappings = varMappingsWithParams }

        exprResult : ExprResult
        exprResult =
            generateExpr ctxWithArgs lambda.body

        -- Lambda returns use !eco.value (boxed calling convention)
        -- Box the result if needed
        ( boxOps, finalResultVar, ctxAfterBox ) =
            boxToEcoValue exprResult.ctx exprResult.resultVar exprResult.resultType

        ( ctx1, returnOp ) =
            ecoReturn ctxAfterBox finalResultVar ecoValue

        region : MlirRegion
        region =
            mkRegion allArgPairs (unboxOps ++ exprResult.ops ++ boxOps) returnOp

        ( ctx2, funcOp ) =
            funcFunc ctx1 lambda.name allArgPairs ecoValue region
    in
    ( funcOp, ctx2 )



-- ====== GENERATE MAIN ENTRY ======


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



-- ====== GENERATE NODE ======


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
                -- Look up the spec key to get the constructor name
                maybeCtorName : Maybe String
                maybeCtorName =
                    case Mono.lookupSpecKey specId ctx.registry of
                        Just ( Mono.Global _ ctorName, _, _ ) ->
                            Just (Name.toElmString ctorName)

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
            canonicalToMLIRName home ++ "_" ++ sanitizeName name ++ "_$_" ++ String.fromInt specId

        Nothing ->
            "unknown_$_" ++ String.fromInt specId



-- ====== GENERATE DEFINE ======


generateDefine : Context -> String -> Mono.MonoExpr -> Mono.MonoType -> ( MlirOp, Context )
generateDefine ctx funcName expr monoType =
    case expr of
        Mono.MonoClosure closureInfo body _ ->
            generateClosureFunc ctx funcName closureInfo body monoType

        _ ->
            -- Value (thunk) - wrap in nullary function
            let
                -- Thunks have no parameters, but still need fresh scope
                ctxFreshScope : Context
                ctxFreshScope =
                    { ctx | nextVar = 0, varMappings = Dict.empty }

                exprResult : ExprResult
                exprResult =
                    generateExpr ctxFreshScope expr

                retTy =
                    monoTypeToMlir monoType

                -- Handle type mismatch between expression result and expected return type.
                -- Uses symmetric coercion: primitive <-> !eco.value in either direction.
                ( coerceOps, finalVar, ctxFinal ) =
                    coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType retTy

                ( ctx1, returnOp ) =
                    ecoReturn ctxFinal finalVar retTy

                region : MlirRegion
                region =
                    mkRegion [] (exprResult.ops ++ coerceOps) returnOp

                ( ctx2, funcOp ) =
                    funcFunc ctx1 funcName [] retTy region
            in
            ( funcOp, ctx2 )


generateClosureFunc : Context -> String -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ( MlirOp, Context )
generateClosureFunc ctx funcName closureInfo body monoType =
    let
        argPairs : List ( String, MlirType )
        argPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, monoTypeToMlir ty ))
                closureInfo.params

        -- Create fresh varMappings with only function parameters
        freshVarMappings : Dict String ( String, MlirType )
        freshVarMappings =
            List.foldl
                (\( name, ty ) acc ->
                    Dict.insert name ( "%" ++ name, monoTypeToMlir ty ) acc
                )
                Dict.empty
                closureInfo.params

        ctxWithArgs : Context
        ctxWithArgs =
            { ctx | nextVar = List.length closureInfo.params, varMappings = freshVarMappings }

        exprResult : ExprResult
        exprResult =
            generateExpr ctxWithArgs body

        -- Extract return type from the closure's full type, not the body's type.
        -- The body's type may be !eco.value if it's a parameter reference,
        -- but the caller expects the actual return type (e.g., i64 for identity 42).
        ( _, extractedReturnType ) =
            decomposeFunctionType monoType

        returnType : MlirType
        returnType =
            monoTypeToMlir extractedReturnType

        -- Handle type mismatch between expression result and expected return type.
        -- Uses symmetric coercion: primitive <-> !eco.value in either direction.
        ( coerceOps, finalVar, ctxFinal ) =
            coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType returnType

        ( ctx1, returnOp ) =
            ecoReturn ctxFinal finalVar returnType

        region : MlirRegion
        region =
            mkRegion argPairs (exprResult.ops ++ coerceOps) returnOp

        ( ctx2, funcOp ) =
            funcFunc ctx1 funcName argPairs returnType region
    in
    ( funcOp, ctx2 )



-- ====== GENERATE TAIL FUNC ======


generateTailFunc : Context -> String -> List ( Name.Name, Mono.MonoType ) -> Mono.MonoExpr -> Mono.MonoType -> ( MlirOp, Context )
generateTailFunc ctx funcName params expr monoType =
    let
        argPairs : List ( String, MlirType )
        argPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, monoTypeToMlir ty ))
                params

        -- Create fresh varMappings with only function parameters
        freshVarMappings : Dict String ( String, MlirType )
        freshVarMappings =
            List.foldl
                (\( name, ty ) acc ->
                    Dict.insert name ( "%" ++ name, monoTypeToMlir ty ) acc
                )
                Dict.empty
                params

        ctxWithArgs : Context
        ctxWithArgs =
            { ctx | nextVar = List.length params, varMappings = freshVarMappings }

        exprResult : ExprResult
        exprResult =
            generateExpr ctxWithArgs expr

        retTy =
            monoTypeToMlir monoType

        -- Handle type mismatch between expression result and expected return type.
        -- Uses symmetric coercion: primitive <-> !eco.value in either direction.
        ( coerceOps, finalVar, ctxFinal ) =
            coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType retTy

        ( ctx1, returnOp ) =
            ecoReturn ctxFinal finalVar retTy

        region : MlirRegion
        region =
            mkRegion argPairs (exprResult.ops ++ coerceOps) returnOp

        ( ctx2, funcOp ) =
            funcFunc ctx1 funcName argPairs retTy region
    in
    ( funcOp, ctx2 )



-- ====== GENERATE CTOR ======


generateCtor : Context -> String -> Mono.CtorLayout -> Mono.MonoType -> ( Context, MlirOp )
generateCtor ctx funcName ctorLayout monoType =
    let
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
                freshVar ctx

            -- Check for well-known constants that must use eco.constant
            ( ctx2, valueOp ) =
                case constructorName of
                    Just "Nothing" ->
                        ecoConstantNothing ctx1 resultVar

                    Just "True" ->
                        ecoConstantTrue ctx1 resultVar

                    Just "False" ->
                        ecoConstantFalse ctx1 resultVar

                    _ ->
                        -- Not a well-known constant, use eco.construct.custom
                        ecoConstructCustom ctx1 resultVar ctorLayout.tag 0 0 [] constructorName

            ( ctx3, returnOp ) =
                ecoReturn ctx2 resultVar ecoValue

            region : MlirRegion
            region =
                mkRegion [] [ valueOp ] returnOp
        in
        funcFunc ctx3 funcName [] ecoValue region

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
                ecoConstructCustom ctx1 resultVar ctorLayout.tag arity ctorLayout.unboxedBitmap argPairs constructorName

            ( ctx3, returnOp ) =
                ecoReturn ctx2 resultVar ecoValue

            region : MlirRegion
            region =
                mkRegion argPairs [ constructOp ] returnOp
        in
        funcFunc ctx3 funcName argPairs ecoValue region



-- ====== GENERATE ENUM ======


generateEnum : Context -> String -> Int -> Mono.MonoType -> Maybe String -> ( Context, MlirOp )
generateEnum ctx funcName tag _ maybeCtorName =
    let
        ( resultVar, ctx1 ) =
            freshVar ctx

        -- Check for well-known constants that must use eco.constant
        ( ctx2, valueOp ) =
            case maybeCtorName of
                Just "True" ->
                    ecoConstantTrue ctx1 resultVar

                Just "False" ->
                    ecoConstantFalse ctx1 resultVar

                Just "Nothing" ->
                    ecoConstantNothing ctx1 resultVar

                _ ->
                    -- Not a well-known constant, use eco.construct.custom
                    ecoConstructCustom ctx1 resultVar tag 0 0 [] maybeCtorName

        ( ctx3, returnOp ) =
            ecoReturn ctx2 resultVar ecoValue

        region : MlirRegion
        region =
            mkRegion [] [ valueOp ] returnOp
    in
    funcFunc ctx3 funcName [] ecoValue region



-- ====== GENERATE EXTERN ======


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
generateStubValue ctx resultVar _ mlirType =
    -- Use mlirType instead of monoType because mlirType represents the actual
    -- concrete type after monomorphization, which may be a primitive even when
    -- the monoType is a type variable.
    case mlirType of
        I64 ->
            arithConstantInt ctx resultVar 0

        F64 ->
            arithConstantFloat ctx resultVar 0.0

        I1 ->
            arithConstantBool ctx resultVar False

        I16 ->
            arithConstantChar ctx resultVar 0

        _ ->
            -- For all other types (EcoValue, etc.), return Unit
            ecoConstantUnit ctx resultVar


{-| Create a dummy value of the given MLIR type.
Used for case expressions where we need a placeholder result with the correct type
for the return after the eco.case (which will be replaced by the lowering pass).
-}
createDummyValue : Context -> MlirType -> ( List MlirOp, String, Context )
createDummyValue ctx mlirType =
    let
        ( resultVar, ctx1 ) =
            freshVar ctx
    in
    case mlirType of
        I64 ->
            let
                ( ctx2, op ) =
                    arithConstantInt ctx1 resultVar 0
            in
            ( [ op ], resultVar, ctx2 )

        F64 ->
            let
                ( ctx2, op ) =
                    arithConstantFloat ctx1 resultVar 0.0
            in
            ( [ op ], resultVar, ctx2 )

        I1 ->
            let
                ( ctx2, op ) =
                    arithConstantBool ctx1 resultVar False
            in
            ( [ op ], resultVar, ctx2 )

        I16 ->
            let
                ( ctx2, op ) =
                    arithConstantChar ctx1 resultVar 0
            in
            ( [ op ], resultVar, ctx2 )

        _ ->
            -- For ecoValue and other types, return Unit
            let
                ( ctx2, op ) =
                    ecoConstantUnit ctx1 resultVar
            in
            ( [ op ], resultVar, ctx2 )



-- ====== GENERATE CYCLE ======


generateCycle : Context -> String -> List ( Name.Name, Mono.MonoExpr ) -> Mono.MonoType -> ( MlirOp, Context )
generateCycle ctx funcName definitions monoType =
    -- Generate mutually recursive definitions
    -- For now, generate a thunk that creates a record of all the cycle definitions
    let
        -- Generate expressions and collect results with their ACTUAL SSA types
        ( defOps, defVarsWithTypes, finalCtx ) =
            List.foldl
                (\( _, expr ) ( accOps, accVars, accCtx ) ->
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
                definitions

        -- Box any primitive values before storing in the cycle using actual SSA types
        ( boxOps, boxedVars, ctxAfterBox ) =
            boxArgsWithMlirTypes finalCtx defVarsWithTypes

        ( resultVar, ctx1 ) =
            freshVar ctxAfterBox

        arity : Int
        arity =
            List.length definitions

        defVarPairs : List ( String, MlirType )
        defVarPairs =
            List.map (\v -> ( v, ecoValue )) boxedVars

        ( ctx2, cycleOp ) =
            ecoConstructRecord ctx1 resultVar defVarPairs arity 0

        ( ctx3, returnOp ) =
            ecoReturn ctx2 resultVar ecoValue

        region : MlirRegion
        region =
            mkRegion [] (defOps ++ boxOps ++ [ cycleOp ]) returnOp

        ( ctx4, funcOp ) =
            funcFunc ctx3 funcName [] (monoTypeToMlir monoType) region
    in
    ( funcOp, ctx4 )



-- ====== GENERATE EXPRESSION ======


generateExpr : Context -> Mono.MonoExpr -> ExprResult
generateExpr ctx expr =
    case expr of
        Mono.MonoLiteral lit _ ->
            generateLiteral ctx lit

        Mono.MonoVarLocal name _ ->
            let
                ( varName, varType ) =
                    lookupVar ctx name
            in
            emptyResult ctx varName varType

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

        Mono.MonoAccessor _ fieldName _ ->
            generateAccessor ctx fieldName



-- ====== LITERAL GENERATION ======


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
            , resultType = I1
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
            , resultType = ecoInt
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
            , resultType = ecoFloat
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
            , resultType = ecoChar
            , ctx = ctx2
            }

        Mono.LStr value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                -- Empty strings must use eco.constant EmptyString (invariant: never heap-allocated)
                ( ctx2, op ) =
                    if value == "" then
                        ecoConstantEmptyString ctx1 var

                    else
                        ecoStringLiteral ctx1 var value
            in
            { ops = [ op ]
            , resultVar = var
            , resultType = ecoValue
            , ctx = ctx2
            }



-- ====== VARIABLE GENERATION ======


generateVarGlobal : Context -> Mono.SpecId -> Mono.MonoType -> ExprResult
generateVarGlobal ctx specId monoType =
    let
        ( var, ctx1 ) =
            freshVar ctx

        funcName : String
        funcName =
            specIdToFuncName ctx.registry specId

        -- Use the signature table to determine arity, not just monoType.
        -- This is more reliable because monoType might be a type variable (MVar)
        -- even though the underlying function has parameters.
        maybeSig : Maybe FuncSignature
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
                        monoTypeToMlir sig.returnType

                    ( ctx2, callOp ) =
                        ecoCallNamed ctx1 var funcName [] resultMlirType
                in
                { ops = [ callOp ]
                , resultVar = var
                , resultType = resultMlirType
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
                , resultType = ecoValue
                , ctx = ctx2
                }

        Nothing ->
            -- No signature found - fall back to monoType-based logic
            -- This should only happen for primitives or special cases
            case monoType of
                Mono.MFunction _ _ ->
                    let
                        arity : Int
                        arity =
                            countTotalArity monoType
                    in
                    if arity == 0 then
                        let
                            resultMlirType =
                                monoTypeToMlir monoType

                            ( ctx2, callOp ) =
                                ecoCallNamed ctx1 var funcName [] resultMlirType
                        in
                        { ops = [ callOp ]
                        , resultVar = var
                        , resultType = resultMlirType
                        , ctx = ctx2
                        }

                    else
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
                        , resultType = ecoValue
                        , ctx = ctx2
                        }

                _ ->
                    -- Non-function type: call the function directly (e.g., zero-arg constructors)
                    let
                        resultMlirType =
                            monoTypeToMlir monoType

                        ( ctx2, callOp ) =
                            ecoCallNamed ctx1 var funcName [] resultMlirType
                    in
                    { ops = [ callOp ]
                    , resultVar = var
                    , resultType = resultMlirType
                    , ctx = ctx2
                    }


generateVarKernel : Context -> Name.Name -> Name.Name -> Mono.MonoType -> ExprResult
generateVarKernel ctx home name monoType =
    let
        ( var, ctx1 ) =
            freshVar ctx

        kernelName : String
        kernelName =
            "Elm_Kernel_" ++ home ++ "_" ++ name
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
            , resultType = ecoFloat
            , ctx = ctx2
            }

        Just _ ->
            -- Other intrinsic matched with zero args - but check if it's function-typed
            case monoType of
                Mono.MFunction _ _ ->
                    let
                        arity : Int
                        arity =
                            countTotalArity monoType
                    in
                    if arity == 0 then
                        -- Zero-arity function (thunk): call directly
                        let
                            resultMlirType =
                                monoTypeToMlir monoType

                            ( ctx2, callOp ) =
                                ecoCallNamed ctx1 var kernelName [] resultMlirType
                        in
                        { ops = [ callOp ]
                        , resultVar = var
                        , resultType = resultMlirType
                        , ctx = ctx2
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
                                mlirOp ctx1 "eco.papCreate"
                                    |> opBuilder.withResults [ ( var, ecoValue ) ]
                                    |> opBuilder.withAttrs attrs
                                    |> opBuilder.build
                        in
                        { ops = [ papOp ]
                        , resultVar = var
                        , resultType = ecoValue
                        , ctx = ctx2
                        }

                _ ->
                    -- Non-function type: call directly
                    let
                        resultMlirType =
                            monoTypeToMlir monoType

                        ( ctx2, callOp ) =
                            ecoCallNamed ctx1 var kernelName [] resultMlirType
                    in
                    { ops = [ callOp ]
                    , resultVar = var
                    , resultType = resultMlirType
                    , ctx = ctx2
                    }

        Nothing ->
            -- No intrinsic match - check if this is a function type
            case monoType of
                Mono.MFunction _ _ ->
                    let
                        arity : Int
                        arity =
                            countTotalArity monoType
                    in
                    if arity == 0 then
                        -- Zero-arity function (thunk): call directly
                        let
                            resultMlirType =
                                monoTypeToMlir monoType

                            ( ctx2, callOp ) =
                                ecoCallNamed ctx1 var kernelName [] resultMlirType
                        in
                        { ops = [ callOp ]
                        , resultVar = var
                        , resultType = resultMlirType
                        , ctx = ctx2
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
                                mlirOp ctx1 "eco.papCreate"
                                    |> opBuilder.withResults [ ( var, ecoValue ) ]
                                    |> opBuilder.withAttrs attrs
                                    |> opBuilder.build
                        in
                        { ops = [ papOp ]
                        , resultVar = var
                        , resultType = ecoValue
                        , ctx = ctx2
                        }

                _ ->
                    -- Non-function type: call the kernel directly
                    let
                        resultMlirType =
                            monoTypeToMlir monoType

                        ( ctx2, callOp ) =
                            ecoCallNamed ctx1 var kernelName [] resultMlirType
                    in
                    { ops = [ callOp ]
                    , resultVar = var
                    , resultType = resultMlirType
                    , ctx = ctx2
                    }



-- ====== LIST GENERATION ======


generateList : Context -> List Mono.MonoExpr -> ExprResult
generateList ctx items =
    case items of
        [] ->
            -- Empty list: use eco.constant Nil (embedded constant, not heap-allocated)
            let
                ( var, ctx1 ) =
                    freshVar ctx

                ( ctx2, nilOp ) =
                    ecoConstantNil ctx1 var
            in
            { ops = [ nilOp ]
            , resultVar = var
            , resultType = ecoValue
            , ctx = ctx2
            }

        _ ->
            -- Non-empty list: use eco.constant Nil for tail, eco.construct.list for cons cells.
            -- Now that MonoPath carries ContainerKind, projection ops (eco.project.list_head/tail)
            -- match the Cons layout created by eco.construct.list.
            let
                ( nilVar, ctx1 ) =
                    freshVar ctx

                ( ctx2, nilOp ) =
                    ecoConstantNil ctx1 nilVar

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
                                    freshVar ctx3

                                -- Use eco.construct.list to create cons cells with proper Cons layout
                                -- head_unboxed=false since we box all list elements
                                ( ctx5, consOp ) =
                                    ecoConstructList ctx4 consVar ( boxedVar, ecoValue ) ( tailVar, ecoValue ) False
                            in
                            ( accOps ++ result.ops ++ boxOps ++ [ consOp ], consVar, ctx5 )
                        )
                        ( [], nilVar, ctx2 )
                        items
            in
            { ops = nilOp :: consOps
            , resultVar = finalVar
            , resultType = ecoValue
            , ctx = finalCtx
            }



-- ====== CLOSURE GENERATION ======


generateClosure : Context -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ExprResult
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

        -- Box using actual SSA types, not Mono types
        ( boxOps, boxedCaptureVars, ctx1b ) =
            boxArgsWithMlirTypes ctx1 captureVarsWithTypes

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

            closureResultType =
                monoTypeToMlir monoType

            ( ctx4, callOp ) =
                ecoCallNamed ctx3 resultVar (lambdaIdToString closureInfo.lambdaId) [] closureResultType
        in
        { ops = captureOps ++ boxOps ++ [ callOp ]
        , resultVar = resultVar
        , resultType = closureResultType
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
        , resultType = ecoValue
        , ctx = ctx4
        }


lambdaIdToString : Mono.LambdaId -> String
lambdaIdToString lambdaId =
    case lambdaId of
        Mono.AnonymousLambda home uid ->
            canonicalToMLIRName home ++ "_lambda_" ++ String.fromInt uid



-- ====== CALL GENERATION ======


isEcoValueType : MlirType -> Bool
isEcoValueType ty =
    case ty of
        NamedStruct "eco.value" ->
            True

        _ ->
            False


{-| Box a value to !eco.value given its MlirType.
If already !eco.value, returns unchanged.
-}
boxToEcoValue : Context -> String -> MlirType -> ( List MlirOp, String, Context )
boxToEcoValue ctx var mlirTy =
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


{-| Box or unbox arguments (based on ACTUAL SSA types) to match the
function's expected Mono types.
-}
boxToMatchSignatureTyped :
    Context
    -> List ( String, MlirType )
    -> List Mono.MonoType
    -> ( List MlirOp, List ( String, MlirType ), Context )
boxToMatchSignatureTyped ctx actualArgs expectedTypes =
    let
        helper :
            ( ( String, MlirType ), Mono.MonoType )
            -> ( List MlirOp, List ( String, MlirType ), Context )
            -> ( List MlirOp, List ( String, MlirType ), Context )
        helper ( ( var, actualTy ), expectedTy ) ( opsAcc, pairsAcc, ctxAcc ) =
            let
                expectedMlirTy =
                    monoTypeToMlir expectedTy
            in
            if expectedMlirTy == actualTy then
                ( opsAcc, pairsAcc ++ [ ( var, actualTy ) ], ctxAcc )

            else if isEcoValueType expectedMlirTy && not (isEcoValueType actualTy) then
                -- Function expects boxed, we have primitive -> box using actual SSA type
                let
                    ( boxOps, boxedVar, ctx1 ) =
                        boxToEcoValue ctxAcc var actualTy
                in
                ( opsAcc ++ boxOps
                , pairsAcc ++ [ ( boxedVar, ecoValue ) ]
                , ctx1
                )

            else if not (isEcoValueType expectedMlirTy) && isEcoValueType actualTy then
                -- Function expects primitive, we have boxed -> unbox to expected primitive type
                let
                    ( unboxOps, unboxedVar, ctx1 ) =
                        unboxToType ctxAcc var expectedMlirTy
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


mlirTypeToString : MlirType -> String
mlirTypeToString ty =
    case ty of
        I1 ->
            "i1"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct s ->
            "!" ++ s

        FunctionType sig ->
            let
                ins =
                    sig.inputs |> List.map mlirTypeToString |> String.join ", "

                outs =
                    sig.results |> List.map mlirTypeToString |> String.join ", "
            in
            "(" ++ ins ++ ") -> (" ++ outs ++ ")"


{-| Coerce an expression result to a desired MLIR type by inserting
boxing/unboxing ops when the difference is only boxed vs unboxed.
Handles both directions:

  - primitive -> !eco.value (box)
  - !eco.value -> primitive (unbox)

-}
coerceResultToType : Context -> String -> MlirType -> MlirType -> ( List MlirOp, String, Context )
coerceResultToType ctx var actualTy expectedTy =
    if actualTy == expectedTy then
        -- No coercion needed
        ( [], var, ctx )

    else if isEcoValueType expectedTy && not (isEcoValueType actualTy) then
        -- Need primitive -> boxed
        boxToEcoValue ctx var actualTy

    else if not (isEcoValueType expectedTy) && isEcoValueType actualTy then
        -- Need boxed -> primitive
        unboxToType ctx var expectedTy

    else
        -- Types don't match and no boxing/unboxing solution
        -- This indicates a monomorphization bug - primitive type mismatches
        -- (e.g., i64 vs f64) should have been resolved upstream
        crash <|
            "coerceResultToType: cannot coerce "
                ++ mlirTypeToString actualTy
                ++ " to "
                ++ mlirTypeToString expectedTy
                ++ " for variable "
                ++ var


generateCall : Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateCall ctx func args resultType =
    -- If the result type is still a function, this is a partial application.
    -- Route through the closure path to avoid direct calls with insufficient args.
    if isFunctionType resultType then
        generateClosureApplication ctx func args resultType

    else
        generateSaturatedCall ctx func args resultType


{-| Generate a partial application where the result is still a closure.
This creates a closure via papExtend rather than attempting a direct call.
-}
generateClosureApplication : Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateClosureApplication ctx func args resultType =
    let
        funcResult : ExprResult
        funcResult =
            generateExpr ctx func

        -- Use generateExprListTyped to get actual SSA types
        ( argOps, argsWithTypes, ctx1 ) =
            generateExprListTyped funcResult.ctx args

        -- Box using actual SSA types
        ( boxOps, boxedVars, ctx1b ) =
            boxArgsWithMlirTypes ctx1 argsWithTypes

        ( resVar, ctx2 ) =
            freshVar ctx1b

        allOperandNames : List String
        allOperandNames =
            funcResult.resultVar :: boxedVars

        allOperandTypes : List MlirType
        allOperandTypes =
            List.map (\_ -> ecoValue) allOperandNames

        -- Compute arity from the FUNCTION type, not the result type
        funcType : Mono.MonoType
        funcType =
            Mono.typeOf func

        remainingArity : Int
        remainingArity =
            functionArity funcType

        -- papExtend handles both partial and saturated cases
        papExtendAttrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                , ( "remaining_arity", IntAttr Nothing remainingArity )
                ]

        ( ctx3, papExtendOp ) =
            mlirOp ctx2 "eco.papExtend"
                |> opBuilder.withOperands allOperandNames
                |> opBuilder.withResults [ ( resVar, ecoValue ) ]
                |> opBuilder.withAttrs papExtendAttrs
                |> opBuilder.build

        -- Result is a closure (!eco.value)
        expectedType =
            monoTypeToMlir resultType
    in
    { ops = funcResult.ops ++ argOps ++ boxOps ++ [ papExtendOp ]
    , resultVar = resVar
    , resultType = expectedType
    , ctx = ctx3
    }


{-| Generate a saturated function call where all arguments are provided.
-}
generateSaturatedCall : Context -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> ExprResult
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

                                intrinsicResultType =
                                    intrinsicResultMlirType intrinsic
                            in
                            { ops = argOps ++ [ intrinsicOp ]
                            , resultVar = resVar
                            , resultType = intrinsicResultType
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

                                    -- Use boxToMatchSignatureTyped with actual SSA types
                                    ( boxOps, argVarPairs, ctx1b ) =
                                        boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

                                    ( resVar, ctx2 ) =
                                        freshVar ctx1b

                                    kernelName : String
                                    kernelName =
                                        "Elm_Kernel_" ++ moduleName ++ "_" ++ name

                                    callResultType =
                                        monoTypeToMlir sig.returnType

                                    ( ctx3, callOp ) =
                                        ecoCallNamed ctx2 resVar kernelName argVarPairs callResultType
                                in
                                { ops = argOps ++ boxOps ++ [ callOp ]
                                , resultVar = resVar
                                , resultType = callResultType
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
                                                -- Use boxToMatchSignatureTyped with actual SSA types
                                                boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

                                            Nothing ->
                                                -- No signature: use actual SSA types
                                                ( [], argsWithTypes, ctx1 )

                                    ( resultVar, ctx2 ) =
                                        freshVar ctx1b

                                    callResultType =
                                        monoTypeToMlir resultType

                                    ( ctx3, callOp ) =
                                        ecoCallNamed ctx2 resultVar funcName argVarPairs callResultType
                                in
                                { ops = argOps ++ boxOps ++ [ callOp ]
                                , resultVar = resultVar
                                , resultType = callResultType
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

                        -- Use boxToMatchSignatureTyped with actual SSA types
                        ( boxOps, argVarPairs, ctx1b ) =
                            case maybeSig of
                                Just sig ->
                                    boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

                                Nothing ->
                                    -- No signature: use actual SSA types
                                    ( [], argsWithTypes, ctx1 )

                        ( resultVar, ctx2 ) =
                            freshVar ctx1b

                        callResultType =
                            monoTypeToMlir resultType

                        ( ctx3, callOp ) =
                            ecoCallNamed ctx2 resultVar funcName argVarPairs callResultType
                    in
                    { ops = argOps ++ boxOps ++ [ callOp ]
                    , resultVar = resultVar
                    , resultType = callResultType
                    , ctx = ctx3
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
                            if isEcoValueType baseType then
                                unboxToType ctx1 baseVar F64

                            else
                                ( [], baseVar, ctx1 )

                        -- Unbox xVar if needed
                        ( unboxXOps, unboxedXVar, ctx1b ) =
                            if isEcoValueType xType then
                                unboxToType ctx1a xVar F64

                            else
                                ( [], xVar, ctx1a )

                        ( logXVar, ctx2 ) =
                            freshVar ctx1b

                        ( logBaseVar, ctx3 ) =
                            freshVar ctx2

                        ( resVar, _ ) =
                            freshVar ctx3

                        ( ctx5, logXOp ) =
                            ecoUnaryOp ctx2 "eco.float.log" logXVar ( unboxedXVar, F64 ) F64

                        ( ctx6, logBaseOp ) =
                            ecoUnaryOp ctx5 "eco.float.log" logBaseVar ( unboxedBaseVar, F64 ) F64

                        ( ctx7, divOp ) =
                            ecoBinaryOp ctx6 "eco.float.div" resVar ( logXVar, F64 ) ( logBaseVar, F64 ) F64
                    in
                    { ops = argOps ++ unboxBaseOps ++ unboxXOps ++ [ logXOp, logBaseOp, divOp ]
                    , resultVar = resVar
                    , resultType = ecoFloat
                    , ctx = ctx7
                    }

                _ ->
                    case kernelIntrinsic home name argTypes resultType of
                        Just intrinsic ->
                            let
                                -- Unbox arguments if needed (e.g., !eco.value -> i64)
                                ( unboxOps, unboxedArgVars, ctx1b ) =
                                    unboxArgsForIntrinsic ctx1 argsWithTypes intrinsic

                                ( resVar, ctx2 ) =
                                    freshVar ctx1b

                                ( ctx3, intrinsicOp ) =
                                    generateIntrinsicOp ctx2 intrinsic resVar unboxedArgVars

                                intrinsicResType =
                                    intrinsicResultMlirType intrinsic
                            in
                            { ops = argOps ++ unboxOps ++ [ intrinsicOp ]
                            , resultVar = resVar
                            , resultType = intrinsicResType
                            , ctx = ctx3
                            }

                        Nothing ->
                            -- Check if this is a polymorphic kernel function (e.g., Debug.log)
                            -- For polymorphic kernels, all arguments must be boxed as !eco.value
                            if isPolymorphicKernel home name then
                                let
                                    -- Box using the actual SSA types
                                    ( boxOps, boxedVars, ctx1b ) =
                                        boxArgsWithMlirTypes ctx1 argsWithTypes

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
                                , resultType = ecoValue
                                , ctx = ctx3
                                }

                            else
                                -- Generic kernel ABI path
                                let
                                    elmSig : FuncSignature
                                    elmSig =
                                        kernelFuncSignatureFromType funcType

                                    sig : FuncSignature
                                    sig =
                                        case actualKernelAbi home name of
                                            Just abi ->
                                                abi

                                            Nothing ->
                                                elmSig

                                    -- Use boxToMatchSignatureTyped with actual SSA types
                                    ( boxOps, argVarPairs, ctx1b ) =
                                        boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

                                    ( resVar, ctx2 ) =
                                        freshVar ctx1b

                                    kernelName : String
                                    kernelName =
                                        "Elm_Kernel_" ++ home ++ "_" ++ name

                                    kernelResultType =
                                        monoTypeToMlir sig.returnType

                                    ( ctx3, callOp ) =
                                        ecoCallNamed ctx2 resVar kernelName argVarPairs kernelResultType

                                    elmResultType =
                                        monoTypeToMlir elmSig.returnType

                                    needsBoxing =
                                        isEcoValueType elmResultType && not (isEcoValueType kernelResultType)
                                in
                                if needsBoxing then
                                    let
                                        ( boxResultOps, boxedVar, ctx4 ) =
                                            boxToEcoValue ctx3 resVar kernelResultType
                                    in
                                    { ops = argOps ++ boxOps ++ [ callOp ] ++ boxResultOps
                                    , resultVar = boxedVar
                                    , resultType = ecoValue
                                    , ctx = ctx4
                                    }

                                else
                                    { ops = argOps ++ boxOps ++ [ callOp ]
                                    , resultVar = resVar
                                    , resultType = kernelResultType
                                    , ctx = ctx3
                                    }

        Mono.MonoVarLocal name funcType ->
            let
                -- Use generateExprListTyped to get actual SSA types
                ( argOps, argsWithTypes, ctx1 ) =
                    generateExprListTyped ctx args

                -- Box using actual SSA types
                ( boxOps, boxedVars, ctx1b ) =
                    boxArgsWithMlirTypes ctx1 argsWithTypes

                ( resVar, ctx2 ) =
                    freshVar ctx1b

                ( funcVarName, _ ) =
                    lookupVar ctx name

                allOperandNames : List String
                allOperandNames =
                    funcVarName :: boxedVars

                allOperandTypes : List MlirType
                allOperandTypes =
                    List.map (\_ -> ecoValue) allOperandNames

                -- Compute arity from the FUNCTION type, not the result type
                remainingArity : Int
                remainingArity =
                    functionArity funcType

                -- papExtend handles both partial and saturated cases
                papExtendAttrs =
                    Dict.fromList
                        [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                        , ( "remaining_arity", IntAttr Nothing remainingArity )
                        ]

                ( ctx3, papExtendOp ) =
                    mlirOp ctx2 "eco.papExtend"
                        |> opBuilder.withOperands allOperandNames
                        |> opBuilder.withResults [ ( resVar, ecoValue ) ]
                        |> opBuilder.withAttrs papExtendAttrs
                        |> opBuilder.build

                -- If the expected result type is primitive, unbox it
                expectedType =
                    monoTypeToMlir resultType

                ( unboxOps, finalVar, ctx4 ) =
                    if isEcoValueType expectedType then
                        ( [], resVar, ctx3 )

                    else
                        let
                            ( unboxVar, ctxU ) =
                                freshVar ctx3

                            attrs =
                                Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr ecoValue ])

                            ( ctxU2, unboxOp ) =
                                mlirOp ctxU "eco.unbox"
                                    |> opBuilder.withOperands [ resVar ]
                                    |> opBuilder.withResults [ ( unboxVar, expectedType ) ]
                                    |> opBuilder.withAttrs attrs
                                    |> opBuilder.build
                        in
                        ( [ unboxOp ], unboxVar, ctxU2 )
            in
            { ops = argOps ++ boxOps ++ [ papExtendOp ] ++ unboxOps
            , resultVar = finalVar
            , resultType = expectedType
            , ctx = ctx4
            }

        _ ->
            let
                funcResult : ExprResult
                funcResult =
                    generateExpr ctx func

                -- Use generateExprListTyped to get actual SSA types
                ( argOps, argsWithTypes, ctx1 ) =
                    generateExprListTyped funcResult.ctx args

                -- Box using actual SSA types
                ( boxOps, boxedVars, ctx1b ) =
                    boxArgsWithMlirTypes ctx1 argsWithTypes

                ( resVar, ctx2 ) =
                    freshVar ctx1b

                allOperandNames : List String
                allOperandNames =
                    funcResult.resultVar :: boxedVars

                allOperandTypes : List MlirType
                allOperandTypes =
                    List.map (\_ -> ecoValue) allOperandNames

                -- Compute arity from the FUNCTION type, not the result type
                funcType : Mono.MonoType
                funcType =
                    Mono.typeOf func

                remainingArity : Int
                remainingArity =
                    functionArity funcType

                -- papExtend handles both partial and saturated cases
                papExtendAttrs =
                    Dict.fromList
                        [ ( "_operand_types", ArrayAttr Nothing (List.map TypeAttr allOperandTypes) )
                        , ( "remaining_arity", IntAttr Nothing remainingArity )
                        ]

                ( ctx3, papExtendOp ) =
                    mlirOp ctx2 "eco.papExtend"
                        |> opBuilder.withOperands allOperandNames
                        |> opBuilder.withResults [ ( resVar, ecoValue ) ]
                        |> opBuilder.withAttrs papExtendAttrs
                        |> opBuilder.build

                -- If the expected result type is primitive, unbox it
                expectedType =
                    monoTypeToMlir resultType

                ( unboxOps, finalVar, ctx4 ) =
                    if isEcoValueType expectedType then
                        ( [], resVar, ctx3 )

                    else
                        let
                            ( unboxVar, ctxU ) =
                                freshVar ctx3

                            attrs =
                                Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr ecoValue ])

                            ( ctxU2, unboxOp ) =
                                mlirOp ctxU "eco.unbox"
                                    |> opBuilder.withOperands [ resVar ]
                                    |> opBuilder.withResults [ ( unboxVar, expectedType ) ]
                                    |> opBuilder.withAttrs attrs
                                    |> opBuilder.build
                        in
                        ( [ unboxOp ], unboxVar, ctxU2 )
            in
            { ops = funcResult.ops ++ argOps ++ boxOps ++ [ papExtendOp ] ++ unboxOps
            , resultVar = finalVar
            , resultType = expectedType
            , ctx = ctx4
            }


{-| Generate expressions and return their ACTUAL MLIR types (not from Mono.typeOf).
This is important when the Mono types may be incorrect/stale, but the generated
SSA values have correct types.
-}
generateExprListTyped : Context -> List Mono.MonoExpr -> ( List MlirOp, List ( String, MlirType ), Context )
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
    Context
    -> List ( String, MlirType )
    -> ( List MlirOp, List String, Context )
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


generateTailCall : Context -> Name.Name -> List ( Name.Name, Mono.MonoExpr ) -> ExprResult
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

        ( ctx4, unitOp ) =
            ecoConstantUnit ctx3 resultVar
    in
    { ops = argsOps ++ [ jumpOp, unitOp ]
    , resultVar = resultVar
    , resultType = ecoValue
    , ctx = ctx4
    }



-- ====== IF GENERATION ======


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
                -- Evaluate condition to Bool (produces i1)
                condRes =
                    generateExpr ctx condExpr

                condVar =
                    condRes.resultVar

                -- Generate then branch first to get its actual result type
                thenRes =
                    generateExpr condRes.ctx thenExpr

                -- Use the then branch's actual SSA type as the result type
                resultMlirType =
                    thenRes.resultType

                -- Coerce then result to target type if needed
                ( thenCoerceOps, thenFinalVar, thenFinalCtx ) =
                    coerceResultToType thenRes.ctx thenRes.resultVar thenRes.resultType resultMlirType

                ( ctx1, thenYieldOp ) =
                    scfYield thenFinalCtx thenFinalVar resultMlirType

                thenRegion =
                    mkRegion [] (thenRes.ops ++ thenCoerceOps) thenYieldOp

                -- Generate else branch (recursive if or final) with scf.yield
                elseRes =
                    generateIf ctx1 restBranches final

                -- Coerce else result to match then branch's type
                ( elseCoerceOps, elseFinalVar, elseFinalCtx ) =
                    coerceResultToType elseRes.ctx elseRes.resultVar elseRes.resultType resultMlirType

                ( ctx2, elseYieldOp ) =
                    scfYield elseFinalCtx elseFinalVar resultMlirType

                elseRegion =
                    mkRegion [] (elseRes.ops ++ elseCoerceOps) elseYieldOp

                -- Allocate result variable for scf.if
                ( ifResultVar, ctx2b ) =
                    freshVar ctx2

                -- scf.if with i1 condition directly (avoids eco.get_tag on embedded constants)
                ( ctx3, ifOp ) =
                    scfIf ctx2b condVar ifResultVar thenRegion elseRegion resultMlirType
            in
            { ops = condRes.ops ++ [ ifOp ]
            , resultVar = ifResultVar
            , resultType = resultMlirType
            , ctx = ctx3
            }



-- ====== LET GENERATION ======


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
                    addVarMapping name exprResult.resultVar exprResult.resultType exprResult.ctx

                bodyResult : ExprResult
                bodyResult =
                    generateExpr ctx1 body
            in
            { ops = exprResult.ops ++ bodyResult.ops
            , resultVar = bodyResult.resultVar
            , resultType = bodyResult.resultType
            , ctx = bodyResult.ctx
            }

        Mono.MonoTailDef _ _ ->
            generateExpr ctx body



-- ====== DESTRUCT GENERATION ======


generateDestruct : Context -> Mono.MonoDestructor -> Mono.MonoExpr -> Mono.MonoType -> ExprResult
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
            monoTypeToMlir monoType

        -- Always use the destructor's type for path generation
        targetType =
            destructorMlirType

        ( pathOps, pathVar, ctx1 ) =
            generateMonoPath ctx path targetType

        -- Use mapping instead of eco.construct wrapper
        ctx2 : Context
        ctx2 =
            addVarMapping name pathVar targetType ctx1

        bodyResult : ExprResult
        bodyResult =
            generateExpr ctx2 body
    in
    { ops = pathOps ++ bodyResult.ops
    , resultVar = bodyResult.resultVar
    , resultType = bodyResult.resultType
    , ctx = bodyResult.ctx
    }


generateMonoPath : Context -> Mono.MonoPath -> MlirType -> ( List MlirOp, String, Context )
generateMonoPath ctx path targetType =
    case path of
        Mono.MonoRoot name ->
            let
                ( varName, _ ) =
                    lookupVar ctx name
            in
            ( [], varName, ctx )

        Mono.MonoIndex index containerKind subPath ->
            let
                -- Navigate to the container object (always !eco.value)
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath ecoValue

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                -- Use type-specific projection ops based on ContainerKind.
                -- This ensures correct heap layout access for each container type.
                ( ctx3, projectOp ) =
                    case containerKind of
                        Mono.ListContainer ->
                            if index == 0 then
                                -- List head
                                ecoProjectListHead ctx2 resultVar targetType subVar

                            else
                                -- List tail (index 1)
                                ecoProjectListTail ctx2 resultVar subVar

                        Mono.Tuple2Container ->
                            ecoProjectTuple2 ctx2 resultVar index targetType subVar

                        Mono.Tuple3Container ->
                            ecoProjectTuple3 ctx2 resultVar index targetType subVar

                        Mono.CustomContainer ->
                            -- Type-specific projection for custom ADTs
                            ecoProjectCustom ctx2 resultVar index targetType subVar

                        Mono.RecordContainer ->
                            -- Type-specific projection for records
                            ecoProjectRecord ctx2 resultVar index targetType subVar
            in
            ( subOps ++ [ projectOp ]
            , resultVar
            , ctx3
            )

        Mono.MonoField index subPath ->
            let
                -- Navigate to the container object (always !eco.value)
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath ecoValue

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                -- Project directly to the targetType using record projection.
                -- MonoField is generated from TOpt.Field which is record field access.
                -- Primitive types are stored unboxed and should be read directly.
                ( ctx3, projectOp ) =
                    ecoProjectRecord ctx2 resultVar index targetType subVar
            in
            ( subOps ++ [ projectOp ]
            , resultVar
            , ctx3
            )

        Mono.MonoUnbox subPath ->
            -- MonoUnbox is a SEMANTIC operation for single-constructor types.
            -- It means "unwrap the wrapper to access the inner value".
            -- This is a NO-OP in MLIR - the wrapped and unwrapped values have
            -- the same runtime representation (!eco.value).
            --
            -- NOTE: This is different from eco.unbox which converts !eco.value
            -- to a primitive type (i64, f64, etc.). eco.unbox is generated by
            -- MonoIndex when the targetType is a primitive, NOT by MonoUnbox.
            --
            -- By always passing through, we avoid generating incorrect sequences
            -- like: project -> eco.unbox -> project (where eco.unbox produces i64
            -- but the next project expects !eco.value).
            generateMonoPath ctx subPath targetType



-- ====== DECISION TREE PATH GENERATION ======


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
            -- The root is the scrutinee variable; look it up in varMappings.
            -- This correctly handles both boxed (!eco.value) and unboxed (i1, i64) parameters.
            let
                ( rootVar, rootTy ) =
                    lookupVar ctx root
            in
            if rootTy == targetType then
                -- Already the right type (e.g. Bool param already i1)
                ( [], rootVar, ctx )

            else if isEcoValueType rootTy && not (isEcoValueType targetType) then
                -- Currently boxed, need primitive -> unbox and update mapping
                let
                    ( unboxOps, unboxedVar, ctx1 ) =
                        unboxToType ctx rootVar targetType

                    -- Make future uses of root see the unboxed SSA value
                    ctx2 =
                        addVarMapping root unboxedVar targetType ctx1
                in
                ( unboxOps, unboxedVar, ctx2 )

            else
                -- Types differ but we don't have a boxing rule here; just use rootVar.
                ( [], rootVar, ctx )

        DT.Index index hint subPath ->
            let
                -- Navigate to the container object (always !eco.value)
                ( subOps, subVar, ctx1 ) =
                    generateDTPath ctx root subPath ecoValue

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                fieldIndex : Int
                fieldIndex =
                    Index.toMachine index

                -- Use type-specific projection ops based on ContainerHint.
                -- This ensures correct heap layout access for each container type.
                ( ctx3, projectOp ) =
                    case hint of
                        DT.HintList ->
                            if fieldIndex == 0 then
                                -- List head
                                ecoProjectListHead ctx2 resultVar targetType subVar

                            else
                                -- List tail (index 1)
                                ecoProjectListTail ctx2 resultVar subVar

                        DT.HintTuple2 ->
                            ecoProjectTuple2 ctx2 resultVar fieldIndex targetType subVar

                        DT.HintTuple3 ->
                            ecoProjectTuple3 ctx2 resultVar fieldIndex targetType subVar

                        DT.HintCustom ->
                            -- Custom ADTs (Maybe, Result, user types, big tuples)
                            ecoProjectCustom ctx2 resultVar fieldIndex targetType subVar

                        DT.HintUnknown ->
                            -- Fallback: treat like custom
                            ecoProjectCustom ctx2 resultVar fieldIndex targetType subVar
            in
            ( subOps ++ [ projectOp ], resultVar, ctx3 )

        DT.Unbox subPath ->
            -- DT.Unbox is a SEMANTIC operation for single-constructor types.
            -- It means "unwrap the wrapper to access the inner value".
            -- This is a NO-OP in MLIR - the wrapped and unwrapped values have
            -- the same runtime representation (!eco.value).
            --
            -- NOTE: This is different from eco.unbox which converts !eco.value
            -- to a primitive type (i64, f64, etc.). eco.unbox is generated by
            -- DT.Index when the targetType is a primitive, NOT by DT.Unbox.
            --
            -- By always passing through, we avoid generating incorrect sequences
            -- like: project -> eco.unbox -> project (where eco.unbox produces i64
            -- but the next project expects !eco.value).
            generateDTPath ctx root subPath targetType


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
        DT.IsCtor _ _ index _ _ ->
            -- Produce a boolean (i1) by comparing the tag
            let
                expectedTag =
                    Index.toMachine index

                ( tagVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, tagOp ) =
                    ecoGetTag ctx2 tagVar valVar

                ( constVar, ctx4 ) =
                    freshVar ctx3

                ( ctx5, constOp ) =
                    arithConstantInt32 ctx4 constVar expectedTag

                ( resVar, ctx6 ) =
                    freshVar ctx5

                ( ctx7, cmpOp ) =
                    arithCmpI ctx6 "eq" resVar ( tagVar, I32 ) ( constVar, I32 )
            in
            ( pathOps ++ [ tagOp, constOp, cmpOp ], resVar, ctx7 )

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

                -- Empty strings must use eco.constant EmptyString (invariant: never heap-allocated)
                ( ctx3, strOp ) =
                    if s == "" then
                        ecoConstantEmptyString ctx2 strVar

                    else
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
                    arithConstantInt32 ctx4 constVar 1

                ( resVar, ctx6 ) =
                    freshVar ctx5

                ( ctx7, cmpOp ) =
                    arithCmpI ctx6 "eq" resVar ( tagVar, I32 ) ( constVar, I32 )
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
                    arithConstantInt32 ctx4 constVar 0

                ( resVar, ctx6 ) =
                    freshVar ctx5

                ( ctx7, cmpOp ) =
                    arithCmpI ctx6 "eq" resVar ( tagVar, I32 ) ( constVar, I32 )
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



-- ====== CASE GENERATION ======


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

                -- Use the ACTUAL SSA type from branchRes, not Mono.typeOf
                actualTy =
                    branchRes.resultType

                -- Symmetric boxing/unboxing based on actual vs expected type
                ( coerceOps, finalVar, coerceCtx ) =
                    coerceResultToType branchRes.ctx branchRes.resultVar actualTy resultTy

                ( ctx1, retOp ) =
                    ecoReturn coerceCtx finalVar resultTy

                jpRegion =
                    mkRegion [] (branchRes.ops ++ coerceOps) retOp

                -- Continuation: a dummy region with a return (joinpoint semantics require it)
                ( dummyVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, dummyUnitOp ) =
                    ecoConstantUnit ctx2 dummyVar

                ( ctx4, dummyRetOp ) =
                    ecoReturn ctx3 dummyVar resultTy

                contRegion =
                    mkRegion [] [ dummyUnitOp ] dummyRetOp

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

                -- Use the ACTUAL SSA type from branchRes, not Mono.typeOf
                actualTy =
                    branchRes.resultType

                -- Symmetric boxing/unboxing based on actual vs expected type
                ( coerceOps, finalVar, ctx1 ) =
                    coerceResultToType branchRes.ctx branchRes.resultVar actualTy resultTy

                ( ctx2, retOp ) =
                    ecoReturn ctx1 finalVar resultTy
            in
            -- The return op MUST be last so mkRegionFromOps picks it as terminator
            { ops = branchRes.ops ++ coerceOps ++ [ retOp ]
            , resultVar = finalVar
            , resultType = resultTy
            , ctx = ctx2
            }

        Mono.Jump _ ->
            -- Jump to a joinpoint - generate eco.jump
            let
                ( dummyVar, ctx1 ) =
                    freshVar ctx

                ( ctx2, dummyUnitOp ) =
                    ecoConstantUnit ctx1 dummyVar

                ( ctx3, retOp ) =
                    ecoReturn ctx2 dummyVar resultTy
            in
            { ops = [ dummyUnitOp, retOp ]
            , resultVar = dummyVar
            , resultType = resultTy
            , ctx = ctx3
            }


{-| Generate code for a Chain node (test chain with success/failure branches).
-}
generateChain : Context -> Name.Name -> List ( DT.Path, DT.Test ) -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
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
generateChainForBoolADT : Context -> Name.Name -> DT.Path -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateChainForBoolADT ctx root path success failure resultTy =
    let
        -- Get the Bool value (i1 type)
        ( pathOps, boolVar, ctx1 ) =
            generateDTPath ctx root path I1

        -- Generate success branch (True) with eco.return
        thenRes =
            generateDecider ctx1 root success resultTy

        thenRegion =
            mkRegionFromOps thenRes.ops

        -- Generate failure branch (False) with eco.return
        -- Fork context: keep ctx1's variable mappings but advance nextVar to avoid SSA conflicts
        ctxForElse =
            { ctx1 | nextVar = thenRes.ctx.nextVar }

        elseRes =
            generateDecider ctxForElse root failure resultTy

        elseRegion =
            mkRegionFromOps elseRes.ops

        -- eco.case on Bool: tag 1 for True (success), tag 0 for False (failure)
        ( ctx2, caseOp ) =
            ecoCase elseRes.ctx boolVar I1 [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]
    in
    { ops = pathOps ++ [ caseOp ]
    , resultVar = boolVar -- Dummy; control exits via eco.return inside regions
    , resultType = resultTy
    , ctx = ctx2
    }


{-| General case for Chain node: compute boolean condition and dispatch.
Uses eco.case with i1 scrutinee (lowered to scf.if by SCF pass).
-}
generateChainGeneral : Context -> Name.Name -> List ( DT.Path, DT.Test ) -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateChainGeneral ctx root testChain success failure resultTy =
    let
        -- Compute the boolean condition (produces i1)
        ( condOps, condVar, ctx1 ) =
            generateChainCondition ctx root testChain

        -- Generate success branch with eco.return
        thenRes =
            generateDecider ctx1 root success resultTy

        thenRegion =
            mkRegionFromOps thenRes.ops

        -- Generate failure branch with eco.return
        -- Fork context: keep ctx1's variable mappings but advance nextVar to avoid SSA conflicts
        ctxForElse =
            { ctx1 | nextVar = thenRes.ctx.nextVar }

        elseRes =
            generateDecider ctxForElse root failure resultTy

        elseRegion =
            mkRegionFromOps elseRes.ops

        -- eco.case on Bool: tag 1 for True (success), tag 0 for False (failure)
        ( ctx2, caseOp ) =
            ecoCase elseRes.ctx condVar I1 [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]
    in
    { ops = condOps ++ [ caseOp ]
    , resultVar = condVar -- Dummy; control exits via eco.return inside regions
    , resultType = resultTy
    , ctx = ctx2
    }


{-| Generate code for a FanOut node (multi-way branching on constructor tags).
-}
generateFanOut : Context -> Name.Name -> DT.Path -> List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
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
generateBoolFanOut : Context -> Name.Name -> DT.Path -> List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateBoolFanOut ctx root path edges fallback resultTy =
    let
        -- Get the Bool value as i1 type
        ( pathOps, boolVar, ctx1 ) =
            generateDTPath ctx root path I1

        -- Find True and False branches
        ( trueBranch, falseBranch ) =
            findBoolBranches edges fallback

        -- Generate True branch (tag 1) with eco.return
        thenRes =
            generateDecider ctx1 root trueBranch resultTy

        thenRegion =
            mkRegionFromOps thenRes.ops

        -- Generate False branch (tag 0) with eco.return
        -- Fork context: keep ctx1's variable mappings but advance nextVar to avoid SSA conflicts
        ctxForElse =
            { ctx1 | nextVar = thenRes.ctx.nextVar }

        elseRes =
            generateDecider ctxForElse root falseBranch resultTy

        elseRegion =
            mkRegionFromOps elseRes.ops

        -- eco.case on Bool: tag 1 for True, tag 0 for False
        -- Regions: [True region, False region] corresponding to tags [1, 0]
        ( ctx2, caseOp ) =
            ecoCase elseRes.ctx boolVar I1 [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]
    in
    { ops = pathOps ++ [ caseOp ]
    , resultVar = boolVar -- Dummy; control exits via eco.return inside regions
    , resultType = resultTy
    , ctx = ctx2
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


{-| General case FanOut using eco.case (for non-Bool ADT patterns).
eco.case accepts !eco.value scrutinee; for Bool patterns, generateBoolFanOut uses i1.
-}
generateFanOutGeneral : Context -> Name.Name -> DT.Path -> List ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Mono.Decider Mono.MonoChoice -> MlirType -> ExprResult
generateFanOutGeneral ctx root path edges fallback resultTy =
    let
        -- For ADT patterns, use !eco.value scrutinee (boxed heap pointer)
        -- The runtime extracts the tag from the boxed value
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

        -- eco.case always uses !eco.value for scrutinee
        ( ctx3, caseOp ) =
            ecoCase fallbackRes.ctx scrutineeVar ecoValue tags allRegions [ resultTy ]
    in
    -- Return the case op - no dummy construct between case and return!
    -- The lowering pattern expects: eco.case ... eco.return
    -- Use scrutineeVar as placeholder resultVar - the lowering will replace everything
    { ops = pathOps ++ [ caseOp ]
    , resultVar = scrutineeVar
    , resultType = resultTy
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

        -- Create a dummy result value BEFORE the decision tree.
        -- This is critical for the SCF lowering pattern which expects:
        --   eco.case ... eco.return
        -- If we generate the dummy value AFTER eco.case, it breaks the pattern.
        -- The dummy value is just a placeholder - the lowering pass will replace
        -- the eco.return with the actual scf.if/scf.index_switch results.
        ( dummyOps, dummyVar, ctx1b ) =
            createDummyValue ctx1 resultMlirType

        -- Generate decision tree control flow
        decisionResult =
            generateDecider ctx1b root decider resultMlirType
    in
    -- Return dummyVar which has the correct resultMlirType.
    -- The actual control flow exits via eco.return inside the decision tree regions.
    -- The outer function will add another eco.return using dummyVar, which has the right type.
    -- The lowering pass will transform eco.case into scf.if/scf.index_switch and handle the returns.
    { ops = joinpointOps ++ dummyOps ++ decisionResult.ops
    , resultVar = dummyVar
    , resultType = resultMlirType
    , ctx = decisionResult.ctx
    }



-- ====== RECORD GENERATION ======


generateRecordCreate : Context -> List Mono.MonoExpr -> Mono.RecordLayout -> ExprResult
generateRecordCreate ctx fields layout =
    -- Empty records must use eco.constant EmptyRec (invariant: never heap-allocated)
    if layout.fieldCount == 0 then
        let
            ( resultVar, ctx1 ) =
                freshVar ctx

            ( ctx2, emptyRecOp ) =
                ecoConstantEmptyRec ctx1 resultVar
        in
        { ops = [ emptyRecOp ]
        , resultVar = resultVar
        , resultType = ecoValue
        , ctx = ctx2
        }

    else
        let
            -- Use generateExprListTyped to get actual SSA types
            ( fieldsOps, fieldVarsWithTypes, ctx1 ) =
                generateExprListTyped ctx fields

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

            -- Use eco.construct.record for records
            ( ctx4, constructOp ) =
                ecoConstructRecord ctx3 resultVar fieldVarPairs layout.fieldCount layout.unboxedBitmap
        in
        { ops = fieldsOps ++ boxOps ++ [ constructOp ]
        , resultVar = resultVar
        , resultType = ecoValue
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
                ecoProjectRecord ctx1 projectVar index fieldMlirType recordResult.resultVar
        in
        { ops = recordResult.ops ++ [ projectOp ]
        , resultVar = projectVar
        , resultType = fieldMlirType
        , ctx = ctx2
        }

    else if isEcoValueType fieldMlirType then
        -- Field is boxed and semantic type is also !eco.value - just project
        let
            ( ctx2, projectOp ) =
                ecoProjectRecord ctx1 projectVar index ecoValue recordResult.resultVar
        in
        { ops = recordResult.ops ++ [ projectOp ]
        , resultVar = projectVar
        , resultType = ecoValue
        , ctx = ctx2
        }

    else
        -- Field is stored boxed but semantic type is primitive
        -- Project to get !eco.value, then unbox to primitive type
        let
            ( ctx2, projectOp ) =
                ecoProjectRecord ctx1 projectVar index ecoValue recordResult.resultVar

            ( unboxOps, unboxedVar, ctx3 ) =
                unboxToType ctx2 projectVar fieldMlirType
        in
        { ops = recordResult.ops ++ [ projectOp ] ++ unboxOps
        , resultVar = unboxedVar
        , resultType = fieldMlirType
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
            ecoConstructRecord ctx1 resultVar [ ( recordResult.resultVar, ecoValue ) ] 1 0
    in
    { ops = recordResult.ops ++ [ constructOp ]
    , resultVar = resultVar
    , resultType = ecoValue
    , ctx = ctx2
    }



-- ====== TUPLE GENERATION ======


generateTupleCreate : Context -> List Mono.MonoExpr -> Mono.TupleLayout -> ExprResult
generateTupleCreate ctx elements layout =
    let
        -- Use generateExprListTyped to get actual SSA types
        ( elemOps, elemVarsWithTypes, ctx1 ) =
            generateExprListTyped ctx elements

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
            freshVar ctx2

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
                boxedElemVars
                layout.elements

        -- Use type-specific tuple construction ops.
        -- Now that MonoPath carries ContainerKind, projection ops match construction layout.
        ( ctx4, constructOp ) =
            case elemVarPairs of
                [ ( aVar, aType ), ( bVar, bType ) ] ->
                    -- 2-tuple: use eco.construct.tuple2
                    ecoConstructTuple2 ctx3 resultVar ( aVar, aType ) ( bVar, bType ) layout.unboxedBitmap

                [ ( aVar, aType ), ( bVar, bType ), ( cVar, cType ) ] ->
                    -- 3-tuple: use eco.construct.tuple3
                    ecoConstructTuple3 ctx3 resultVar ( aVar, aType ) ( bVar, bType ) ( cVar, cType ) layout.unboxedBitmap

                _ ->
                    -- Elm rejects tuples with >3 elements during canonicalization
                    crash "Compiler.Generate.CodeGen.MLIR" "generateTupleCreate" "unreachable: tuples >3 elements rejected by canonicalization"
    in
    { ops = elemOps ++ boxOps ++ [ constructOp ]
    , resultVar = resultVar
    , resultType = ecoValue
    , ctx = ctx4
    }



-- ====== UNIT GENERATION ======


generateUnit : Context -> ExprResult
generateUnit ctx =
    let
        ( var, ctx1 ) =
            freshVar ctx

        -- Use eco.constant Unit instead of heap-allocating
        ( ctx2, unitOp ) =
            ecoConstantUnit ctx1 var
    in
    { ops = [ unitOp ]
    , resultVar = var
    , resultType = ecoValue
    , ctx = ctx2
    }



-- ====== ACCESSOR GENERATION ======


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
    , resultType = ecoValue
    , ctx = ctx2
    }



-- ====== INVARIANT CHECKS ======
-- ====== HELPERS ======


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



-- ====== ECO DIALECT OP HELPERS ======


opBuilder : Mlir.OpBuilderFns e
opBuilder =
    Mlir.opBuilder


mlirOp : Context -> String -> Mlir.OpBuilder Context
mlirOp env =
    Mlir.mlirOp (\e -> freshOpId e |> (\( id, ctx ) -> ( ctx, id ))) env


{-| eco.constant - create an embedded constant value.

Constants from Ops.td (1-indexed for MLIR):

  - Unit = 1
  - EmptyRec = 2
  - True = 3
  - False = 4
  - Nil = 5
  - Nothing = 6
  - EmptyString = 7

-}
ecoConstantUnit : Context -> String -> ( Context, MlirOp )
ecoConstantUnit ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 1))
        |> opBuilder.build


ecoConstantEmptyRec : Context -> String -> ( Context, MlirOp )
ecoConstantEmptyRec ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 2))
        |> opBuilder.build


ecoConstantTrue : Context -> String -> ( Context, MlirOp )
ecoConstantTrue ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 3))
        |> opBuilder.build


ecoConstantFalse : Context -> String -> ( Context, MlirOp )
ecoConstantFalse ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 4))
        |> opBuilder.build


ecoConstantNil : Context -> String -> ( Context, MlirOp )
ecoConstantNil ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 5))
        |> opBuilder.build


ecoConstantNothing : Context -> String -> ( Context, MlirOp )
ecoConstantNothing ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 6))
        |> opBuilder.build


ecoConstantEmptyString : Context -> String -> ( Context, MlirOp )
ecoConstantEmptyString ctx resultVar =
    mlirOp ctx "eco.constant"
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs (Dict.singleton "kind" (IntAttr (Just I32) 7))
        |> opBuilder.build


{-| eco.construct.list - create a list cons cell
-}
ecoConstructList : Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> Bool -> ( Context, MlirOp )
ecoConstructList ctx resultVar ( headVar, headType ) ( tailVar, tailType ) headUnboxed =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr headType, TypeAttr tailType ] )
                , ( "head_unboxed", BoolAttr headUnboxed )
                ]
    in
    mlirOp ctx "eco.construct.list"
        |> opBuilder.withOperands [ headVar, tailVar ]
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.construct.tuple2 - create a 2-tuple
-}
ecoConstructTuple2 : Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> Int -> ( Context, MlirOp )
ecoConstructTuple2 ctx resultVar ( aVar, aType ) ( bVar, bType ) unboxedBitmap =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr aType, TypeAttr bType ] )
                , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                ]
    in
    mlirOp ctx "eco.construct.tuple2"
        |> opBuilder.withOperands [ aVar, bVar ]
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.construct.tuple3 - create a 3-tuple
-}
ecoConstructTuple3 : Context -> String -> ( String, MlirType ) -> ( String, MlirType ) -> ( String, MlirType ) -> Int -> ( Context, MlirOp )
ecoConstructTuple3 ctx resultVar ( aVar, aType ) ( bVar, bType ) ( cVar, cType ) unboxedBitmap =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr aType, TypeAttr bType, TypeAttr cType ] )
                , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                ]
    in
    mlirOp ctx "eco.construct.tuple3"
        |> opBuilder.withOperands [ aVar, bVar, cVar ]
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.construct.record - create a record
-}
ecoConstructRecord : Context -> String -> List ( String, MlirType ) -> Int -> Int -> ( Context, MlirOp )
ecoConstructRecord ctx resultVar fieldPairs fieldCount unboxedBitmap =
    let
        operandNames =
            List.map Tuple.first fieldPairs

        operandTypesAttr =
            if List.isEmpty fieldPairs then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map (\( _, t ) -> TypeAttr t) fieldPairs))

        attrs =
            Dict.union operandTypesAttr
                (Dict.fromList
                    [ ( "field_count", IntAttr Nothing fieldCount )
                    , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                    ]
                )
    in
    mlirOp ctx "eco.construct.record"
        |> opBuilder.withOperands operandNames
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.construct.custom - create a custom ADT value
-}
ecoConstructCustom : Context -> String -> Int -> Int -> Int -> List ( String, MlirType ) -> Maybe String -> ( Context, MlirOp )
ecoConstructCustom ctx resultVar tag size unboxedBitmap operands maybeCtorName =
    let
        operandNames =
            List.map Tuple.first operands

        operandTypesAttr =
            if List.isEmpty operands then
                Dict.empty

            else
                Dict.singleton "_operand_types"
                    (ArrayAttr Nothing (List.map (\( _, t ) -> TypeAttr t) operands))

        constructorAttr =
            case maybeCtorName of
                Just name ->
                    Dict.singleton "constructor" (StringAttr name)

                Nothing ->
                    Dict.empty

        attrs =
            Dict.union operandTypesAttr
                (Dict.union constructorAttr
                    (Dict.fromList
                        [ ( "tag", IntAttr Nothing tag )
                        , ( "size", IntAttr Nothing size )
                        , ( "unboxed_bitmap", IntAttr Nothing unboxedBitmap )
                        ]
                    )
                )
    in
    mlirOp ctx "eco.construct.custom"
        |> opBuilder.withOperands operandNames
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.project.list\_head - extract head from a cons cell
-}
ecoProjectListHead : Context -> String -> MlirType -> String -> ( Context, MlirOp )
ecoProjectListHead ctx resultVar resultType listVar =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr ecoValue ])
    in
    mlirOp ctx "eco.project.list_head"
        |> opBuilder.withOperands [ listVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.project.list\_tail - extract tail from a cons cell
-}
ecoProjectListTail : Context -> String -> String -> ( Context, MlirOp )
ecoProjectListTail ctx resultVar listVar =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr ecoValue ])
    in
    mlirOp ctx "eco.project.list_tail"
        |> opBuilder.withOperands [ listVar ]
        |> opBuilder.withResults [ ( resultVar, ecoValue ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.project.tuple2 - extract field from a 2-tuple
-}
ecoProjectTuple2 : Context -> String -> Int -> MlirType -> String -> ( Context, MlirOp )
ecoProjectTuple2 ctx resultVar field resultType tupleVar =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr ecoValue ] )
                , ( "field", IntAttr Nothing field )
                ]
    in
    mlirOp ctx "eco.project.tuple2"
        |> opBuilder.withOperands [ tupleVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.project.tuple3 - extract field from a 3-tuple
-}
ecoProjectTuple3 : Context -> String -> Int -> MlirType -> String -> ( Context, MlirOp )
ecoProjectTuple3 ctx resultVar field resultType tupleVar =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr ecoValue ] )
                , ( "field", IntAttr Nothing field )
                ]
    in
    mlirOp ctx "eco.project.tuple3"
        |> opBuilder.withOperands [ tupleVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.project.record - extract field from a record
-}
ecoProjectRecord : Context -> String -> Int -> MlirType -> String -> ( Context, MlirOp )
ecoProjectRecord ctx resultVar fieldIndex resultType recordVar =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr ecoValue ] )
                , ( "field_index", IntAttr Nothing fieldIndex )
                ]
    in
    mlirOp ctx "eco.project.record"
        |> opBuilder.withOperands [ recordVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| eco.project.custom - extract field from a custom ADT
-}
ecoProjectCustom : Context -> String -> Int -> MlirType -> String -> ( Context, MlirOp )
ecoProjectCustom ctx resultVar fieldIndex resultType containerVar =
    let
        attrs =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr ecoValue ] )
                , ( "field_index", IntAttr Nothing fieldIndex )
                ]
    in
    mlirOp ctx "eco.project.custom"
        |> opBuilder.withOperands [ containerVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
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


{-| arith.constant for i32 integers (used for tags)
-}
arithConstantInt32 : Context -> String -> Int -> ( Context, MlirOp )
arithConstantInt32 ctx resultVar value =
    mlirOp ctx "arith.constant"
        |> opBuilder.withResults [ ( resultVar, I32 ) ]
        |> opBuilder.withAttrs (Dict.singleton "value" (IntAttr (Just I32) value))
        |> opBuilder.build


{-| arith.cmpi for integer comparison (returns i1)
Predicate values: eq=0, ne=1, slt=2, sle=3, sgt=4, sge=5, ult=6, ule=7, ugt=8, uge=9
-}
arithCmpI : Context -> String -> String -> ( String, MlirType ) -> ( String, MlirType ) -> ( Context, MlirOp )
arithCmpI ctx predicateName resultVar ( lhs, lhsTy ) ( rhs, _ ) =
    let
        predicateValue =
            case predicateName of
                "eq" ->
                    0

                "ne" ->
                    1

                "slt" ->
                    2

                "sle" ->
                    3

                "sgt" ->
                    4

                "sge" ->
                    5

                "ult" ->
                    6

                "ule" ->
                    7

                "ugt" ->
                    8

                "uge" ->
                    9

                _ ->
                    0

        attrs =
            Dict.fromList
                [ ( "predicate", IntAttr (Just I64) predicateValue )
                , ( "_operand_types", ArrayAttr Nothing [ TypeAttr lhsTy, TypeAttr lhsTy ] )
                ]
    in
    mlirOp ctx "arith.cmpi"
        |> opBuilder.withOperands [ lhs, rhs ]
        |> opBuilder.withResults [ ( resultVar, I1 ) ]
        |> opBuilder.withAttrs attrs
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
ecoCase : Context -> String -> MlirType -> List Int -> List MlirRegion -> List MlirType -> ( Context, MlirOp )
ecoCase ctx scrutinee scrutineeType tags regions resultTypes =
    let
        attrsBase =
            Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr scrutineeType ] )
                , ( "tags", ArrayAttr (Just I64) (List.map (\t -> IntAttr Nothing t) tags) )
                ]

        attrs =
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


{-| eco.getTag - get the tag from a value (for eco.case scrutinee)
-}
ecoGetTag : Context -> String -> String -> ( Context, MlirOp )
ecoGetTag ctx resultVar operand =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr ecoValue ])
    in
    mlirOp ctx "eco.get_tag"
        |> opBuilder.withOperands [ operand ]
        |> opBuilder.withResults [ ( resultVar, I32 ) ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| scf.if - direct structured control flow for i1 boolean conditions.
Use this for Bool pattern matching instead of eco.case, since eco.case
uses eco.get\_tag which dereferences the value as a pointer.
-}
scfIf : Context -> String -> String -> MlirRegion -> MlirRegion -> MlirType -> ( Context, MlirOp )
scfIf ctx condVar resultVar thenRegion elseRegion resultType =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr I1 ])
    in
    mlirOp ctx "scf.if"
        |> opBuilder.withOperands [ condVar ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.withRegions [ thenRegion, elseRegion ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build


{-| scf.yield - terminator for scf.if regions.
-}
scfYield : Context -> String -> MlirType -> ( Context, MlirOp )
scfYield ctx operand operandType =
    let
        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr operandType ])
    in
    mlirOp ctx "scf.yield"
        |> opBuilder.withOperands [ operand ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.isTerminator True
        |> opBuilder.build
