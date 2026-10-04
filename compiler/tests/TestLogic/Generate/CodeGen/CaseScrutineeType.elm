module TestLogic.Generate.CodeGen.CaseScrutineeType exposing (expectCaseScrutineeType)

{-| The code generator gives each `eco.case` a `case_kind` attribute saying what
kind of value it branches on, and nothing in `Mlir.Mlir` ties that kind to the
type of the value. This module checks, in the MLIR generated for a program,
that the two agree.

The _scrutinee_ of an `eco.case` is the value it branches on, its first
operand. Its type is read from the op's `_operand_types` attribute, as
`TestLogic.Generate.CodeGen.Invariants` describes, so an `eco.case` without
that attribute, or with an empty one, is not checked. The type each kind calls
for is:

  - `int`: `i64`.
  - `chr`: `i16`.
  - `bool`: `i1`.
  - `ctor` and `str`: `!eco.value`.

An `eco.case` with any other `case_kind`, or with none, is not checked.

@docs expectCaseScrutineeType

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , findOpsNamed
        , getStringAttr
        , isEcoValueType
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Compiles `srcModule` to MLIR with `runToMlir` and returns an expectation that
passes when every `eco.case` in the result whose `case_kind` is `int`, `chr`,
`bool`, `ctor` or `str` has a scrutinee of the type that kind calls for: `i64`,
`i16`, `i1`, or `!eco.value` for the last two. An `eco.case` without recorded
operand types is skipped.

It fails with the compilation error when `runToMlir` fails. Otherwise it fails
with the first violation only, as `violationsToExpectation` describes.

-}
expectCaseScrutineeType : Src.Module -> Expectation
expectCaseScrutineeType srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseScrutineeType mlirModule)


{-| Returns a violation for each `eco.case` in `mlirModule`, at any depth, whose
scrutinee type does not match its `case_kind`.
-}
checkCaseScrutineeType : MlirModule -> List Violation
checkCaseScrutineeType mlirModule =
    let
        caseOps =
            findOpsNamed "eco.case" mlirModule
    in
    List.filterMap checkCaseScrutinee caseOps


{-| Returns a violation when the scrutinee type of `op` does not match its
`case_kind`. Returns `Nothing` when it matches, when `op` has no recorded
operand types, and when `case_kind` is missing or not one of the kinds checked.
The name of `op` is not checked.
-}
checkCaseScrutinee : MlirOp -> Maybe Violation
checkCaseScrutinee op =
    let
        maybeOperandTypes =
            extractOperandTypes op

        maybeCaseKind =
            getStringAttr "case_kind" op
    in
    case maybeOperandTypes of
        Nothing ->
            Nothing

        Just [] ->
            Nothing

        Just (scrutineeType :: _) ->
            case maybeCaseKind of
                Just "int" ->
                    if scrutineeType /= I64 then
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message =
                                "case_kind='int' requires i64 scrutinee, got "
                                    ++ typeToString scrutineeType
                            }

                    else
                        Nothing

                Just "chr" ->
                    if scrutineeType /= I16 then
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message =
                                "case_kind='chr' requires i16 (ECO char) scrutinee, got "
                                    ++ typeToString scrutineeType
                            }

                    else
                        Nothing

                Just "ctor" ->
                    if not (isEcoValueType scrutineeType) then
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message =
                                "case_kind='ctor' requires !eco.value scrutinee, got "
                                    ++ typeToString scrutineeType
                            }

                    else
                        Nothing

                Just "str" ->
                    if not (isEcoValueType scrutineeType) then
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message =
                                "case_kind='str' requires !eco.value scrutinee, got "
                                    ++ typeToString scrutineeType
                            }

                    else
                        Nothing

                Just "bool" ->
                    if scrutineeType /= I1 then
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message =
                                "case_kind='bool' requires i1 scrutinee, got "
                                    ++ typeToString scrutineeType
                            }

                    else
                        Nothing

                _ ->
                    Nothing


{-| Returns how `t` is written in a violation message: an integer or float type
as in MLIR, a dialect type by its name without the leading `!` (so `eco.value`),
and any function type as `function`.
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
