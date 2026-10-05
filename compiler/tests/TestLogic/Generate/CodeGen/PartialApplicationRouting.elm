module TestLogic.Generate.CodeGen.PartialApplicationRouting exposing (expectPartialApplicationRouting)

{-| A call that supplies fewer arguments than its function takes must build a
closure (`eco.papCreate`) or add arguments to one (`eco.papExtend`), not be
emitted as an `eco.call` (CGEN\_002). This module checks that every direct
`eco.call` is saturated.

The code generator gives every function value the MLIR type `!eco.value`, so
the result type of an `eco.call` alone cannot reveal an under-saturated call.
Instead `expectPartialApplicationRouting` compiles a program to MLIR, finds for
each `eco.call` the top-level `func.func` its `callee` names (with any leading
`@` removed), and reports the call when

  - its operands, less the trailing GC root hints that `eco.gc_roots_count`
    counts, are fewer or more than the inputs of the callee's `function_type`,
    or
  - its result types are not exactly the results of the callee's
    `function_type`.

An under-applied function would show up as a call with too few operands whose
result stands for the remaining closure instead of the callee's result.

Among what is not tested: an `eco.call` whose callee has no top-level
`func.func` with a `function_type` in the module, and calls through closures,
which are `eco.papExtend` ops.

@docs expectPartialApplicationRouting

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , findOpsNamed
        , getIntAttr
        , getStringAttr
        , getTypeAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that passes when `srcModule` compiles to MLIR with
`runToMlir` and every `eco.call` to a function defined or declared in the
module supplies exactly the callee's inputs and returns exactly its results.

A failed compilation fails with its error. Otherwise only the first violation
found is reported, as `violationsToExpectation` describes.

-}
expectPartialApplicationRouting : Src.Module -> Expectation
expectPartialApplicationRouting srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkPartialApplicationRouting mlirModule)


{-| The inputs and results of a callee's `function_type`.
-}
type alias Signature =
    { inputs : List MlirType
    , results : List MlirType
    }


{-| Returns a violation for each `eco.call` op in `mlirModule`, at any depth,
that does not saturate its callee.
-}
checkPartialApplicationRouting : MlirModule -> List Violation
checkPartialApplicationRouting mlirModule =
    let
        signatures =
            findFuncOps mlirModule
                |> List.filterMap
                    (\op ->
                        case ( getStringAttr "sym_name" op, getTypeAttr "function_type" op ) of
                            ( Just name, Just (FunctionType sig) ) ->
                                Just ( name, sig )

                            _ ->
                                Nothing
                    )
                |> Dict.fromList
    in
    List.filterMap (checkCall signatures) (findOpsNamed "eco.call" mlirModule)


{-| Returns a violation if `op` calls a function in `signatures` with other
than its number of inputs, or with result types other than its results.
-}
checkCall : Dict String Signature -> MlirOp -> Maybe Violation
checkCall signatures op =
    let
        callee =
            getStringAttr "callee" op
                |> Maybe.map
                    (\c ->
                        if String.startsWith "@" c then
                            String.dropLeft 1 c

                        else
                            c
                    )
    in
    case callee |> Maybe.andThen (\c -> Dict.get c signatures |> Maybe.map (Tuple.pair c)) of
        Nothing ->
            Nothing

        Just ( calleeName, sig ) ->
            let
                rootCount =
                    Maybe.withDefault 0 (getIntAttr "eco.gc_roots_count" op)

                argCount =
                    List.length op.operands - rootCount

                inputCount =
                    List.length sig.inputs

                resultTypes =
                    List.map Tuple.second op.results

                violation msg =
                    Just { opId = op.id, opName = op.name, message = "eco.call @" ++ calleeName ++ " " ++ msg }
            in
            if argCount /= inputCount then
                violation
                    ("supplies "
                        ++ String.fromInt argCount
                        ++ " arguments but the callee takes "
                        ++ String.fromInt inputCount
                        ++ "; a partial application must use eco.papCreate/papExtend (CGEN_002)"
                    )

            else if resultTypes /= sig.results then
                violation
                    ("has result types ("
                        ++ String.join ", " (List.map typeToString resultTypes)
                        ++ ") but the callee returns ("
                        ++ String.join ", " (List.map typeToString sig.results)
                        ++ ") (CGEN_002)"
                    )

            else
                Nothing


{-| Returns `t` written in the style of MLIR's textual syntax, for a violation
message. A named struct prints with a leading `!`, as in `!eco.value`.
-}
typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

        I8 ->
            "i8"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct name ->
            "!" ++ name

        FunctionType { inputs, results } ->
            "("
                ++ String.join ", " (List.map typeToString inputs)
                ++ ") -> ("
                ++ String.join ", " (List.map typeToString results)
                ++ ")"
