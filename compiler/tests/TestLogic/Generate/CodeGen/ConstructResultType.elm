module TestLogic.Generate.CodeGen.ConstructResultType exposing (expectConstructResultType)

{-| A construct op builds a boxed value, so the code generator is meant to give
it a single result of type `!eco.value`, the type of a boxed value. This module
checks that rule on the MLIR generated for a test program.

A _construct op_ is any op whose name starts with `eco.construct.`.
`Compiler.Generate.MLIR.Ops` has them for list cells, 2- and 3-tuples, records
and custom-type values. Each one found is reported as a violation, in the sense
of `TestLogic.Generate.CodeGen.Invariants`, if it has a number of results other
than one, or if its one result has a type other than `!eco.value`. Nothing else
about the op is checked: not its operands, not its attributes.

@docs expectConstructResultType

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsWithPrefix
        , isEcoValueType
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR with
`TestLogic.TestPipeline.runToMlir` and passes when every construct op in the
result has exactly one result, of type `!eco.value`.

It fails with the pipeline's error if compilation fails, and otherwise with the
first violation found.

-}
expectConstructResultType : Src.Module -> Expectation
expectConstructResultType srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkConstructResultTypes mlirModule)


{-| Returns a violation for each construct op, at any depth in the module, that
does not have exactly one result of type `!eco.value`.
-}
checkConstructResultTypes : MlirModule -> List Violation
checkConstructResultTypes mlirModule =
    let
        constructOps =
            findOpsWithPrefix "eco.construct." mlirModule
    in
    List.filterMap checkConstructResultTypeSingle constructOps


{-| Returns a violation if `op` has a number of results other than one, or if
its one result is not `!eco.value`, and `Nothing` otherwise.
-}
checkConstructResultTypeSingle : MlirOp -> Maybe Violation
checkConstructResultTypeSingle op =
    let
        resultCount =
            List.length op.results
    in
    if resultCount /= 1 then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                op.name
                    ++ " should have exactly 1 result, has "
                    ++ String.fromInt resultCount
            }

    else
        case List.head op.results of
            Just ( _, resultType ) ->
                if not (isEcoValueType resultType) then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            op.name
                                ++ " result type should be !eco.value, got "
                                ++ typeToString resultType
                        }

                else
                    Nothing

            Nothing ->
                Nothing


{-| Returns a short name for `t`, for a violation message. A named struct is
given by its name alone, without the leading `!`, and a function type is
`function` whatever its inputs and results.
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
            name

        FunctionType _ ->
            "function"
