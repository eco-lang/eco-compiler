module TestLogic.Generate.CodeGen.CharTypeMapping exposing (expectCharTypeMapping, expectCharTypeMappingWithOps)

{-| Checks that the `eco.char.*` ops in the MLIR generated for a program give
the `Char` side the type `i16`, so that a conversion or comparison emitted with
some other width is caught (CGEN\_015).

The code generator's type for a `Char` is `i16`
(`Compiler.Generate.MLIR.Types.ecoChar`), and for an `Int` it is `i64`. An
operand's type here is its _defined_ type: the type of the op result or block
argument that introduces the SSA name within the enclosing top-level op
(`TestLogic.Generate.CodeGen.Invariants.typeEnvOfOp`), not the op's
`_operand_types` record. A violation is reported for:

  - an `eco.char.toInt` that does not take one `i16` operand and give one
    `i64` result;
  - an `eco.char.fromInt` that does not take one `i64` operand and give one
    `i16` result;
  - any other `eco.char.*` op (the comparisons) with an operand that is not
    `i16`;
  - an `eco.char.*` operand with no definition in its top-level op.

Among what is not checked: a `Char` constant, a case on a `Char`, and the
result types of the comparisons.

@docs expectCharTypeMapping, expectCharTypeMappingWithOps

-}

import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( TypeEnv
        , Violation
        , extractResultTypes
        , typeEnvOfOp
        , violationsToExpectation
        , walkAllOps
        , walkOpAndChildren
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Creates an expectation that `srcModule` compiles to MLIR and that its
`eco.char.toInt` operands and `eco.char.fromInt` results are `i16`.

The expectation fails with the test pipeline's error message, prefixed
`Compilation failed:`, if compilation fails, and otherwise with every
violation.

-}
expectCharTypeMapping : Src.Module -> Expectation
expectCharTypeMapping srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCharTypeMapping mlirModule)


{-| Like `expectCharTypeMapping`, and also fails unless the generated MLIR
holds at least one op of each name in `opNames`, so that a focused test cannot
pass because the ops it is about were folded away.
-}
expectCharTypeMappingWithOps : List String -> Src.Module -> Expectation
expectCharTypeMappingWithOps opNames srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            let
                present =
                    List.map .name (walkAllOps mlirModule)

                missing =
                    List.filter (\n -> not (List.member n present)) opNames
            in
            if List.isEmpty missing then
                violationsToExpectation (checkCharTypeMapping mlirModule)

            else
                Expect.fail ("Expected ops not generated: " ++ String.join ", " missing)


{-| Returns the violations of every `eco.char.*` op of `mlirModule`, at any
depth, top-level op by top-level op.
-}
checkCharTypeMapping : MlirModule -> List Violation
checkCharTypeMapping mlirModule =
    List.concatMap
        (\topOp ->
            let
                env =
                    typeEnvOfOp topOp
            in
            walkOpAndChildren topOp
                |> List.filter (\op -> String.startsWith "eco.char." op.name)
                |> List.concatMap (checkCharOp env)
        )
        mlirModule.body


{-| Returns the violations of one `eco.char.*` op, its operand types looked up
in `env`.
-}
checkCharOp : TypeEnv -> MlirOp -> List Violation
checkCharOp env op =
    let
        violation message =
            { opId = op.id, opName = op.name, message = message }

        operandTypes =
            List.map (\name -> ( name, Dict.get name env )) op.operands

        undefinedOperands =
            List.filterMap
                (\( name, t ) ->
                    if t == Nothing then
                        Just (violation (op.name ++ " operand " ++ name ++ " has no definition in its function"))

                    else
                        Nothing
                )
                operandTypes

        conversion inputType resultType =
            case ( operandTypes, extractResultTypes op ) of
                ( [ ( _, Just actualInput ) ], [ actualResult ] ) ->
                    (if actualInput /= inputType then
                        [ violation (op.name ++ " operand should be " ++ typeToString inputType ++ ", got " ++ typeToString actualInput) ]

                     else
                        []
                    )
                        ++ (if actualResult /= resultType then
                                [ violation (op.name ++ " result should be " ++ typeToString resultType ++ ", got " ++ typeToString actualResult) ]

                            else
                                []
                           )

                ( [ ( _, Nothing ) ], _ ) ->
                    []

                _ ->
                    [ violation (op.name ++ " should have exactly one operand and one result") ]
    in
    undefinedOperands
        ++ (case op.name of
                "eco.char.toInt" ->
                    conversion I16 I64

                "eco.char.fromInt" ->
                    conversion I64 I16

                _ ->
                    List.filterMap
                        (\( name, t ) ->
                            case t of
                                Just actual ->
                                    if actual /= I16 then
                                        Just (violation (op.name ++ " operand " ++ name ++ " should be i16, got " ++ typeToString actual))

                                    else
                                        Nothing

                                Nothing ->
                                    Nothing
                        )
                        operandTypes
           )


{-| Returns the MLIR spelling of an integer or float type, as in `i16`, for use
in a violation message. A named struct gives its bare name, without the leading
`!`, and a function type gives the word `function`.
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
