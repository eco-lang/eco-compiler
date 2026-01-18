module Compiler.Generate.CodeGen.CaseScrutineeType exposing
    ( expectCaseScrutineeType
    , checkCaseScrutineeType
    )

{-| Test logic for CGEN_037: Case Scrutinee Type Agreement invariant.

`eco.case` scrutinee is `i1` only for boolean cases; otherwise `!eco.value`.

@docs expectCaseScrutineeType, checkCaseScrutineeType

-}

import Compiler.AST.Source as Src
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , findOpsNamed
        , getStringAttr
        , isEcoValueType
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))


{-| Verify that case scrutinee type invariants hold for a source module.
-}
expectCaseScrutineeType : Src.Module -> Expectation
expectCaseScrutineeType srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseScrutineeType mlirModule)


{-| Check case scrutinee type invariants.
-}
checkCaseScrutineeType : MlirModule -> List Violation
checkCaseScrutineeType mlirModule =
    let
        caseOps =
            findOpsNamed "eco.case" mlirModule

        violations =
            List.filterMap checkCaseScrutinee caseOps
    in
    violations


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
            let
                isBooleanCase =
                    scrutineeType == I1

                caseKindRequiresEcoValue =
                    case maybeCaseKind of
                        Just kind ->
                            List.member kind [ "ctor", "int", "chr", "str" ]

                        Nothing ->
                            False
            in
            if caseKindRequiresEcoValue && not (isEcoValueType scrutineeType) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "case_kind="
                            ++ Maybe.withDefault "?" maybeCaseKind
                            ++ " requires !eco.value scrutinee, got "
                            ++ typeToString scrutineeType
                    }

            else if isBooleanCase && caseKindRequiresEcoValue then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "Boolean case (i1 scrutinee) but case_kind="
                            ++ Maybe.withDefault "?" maybeCaseKind
                            ++ " suggests non-boolean"
                    }

            else
                Nothing


typeToString : MlirType -> String
typeToString t =
    case t of
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

        NamedStruct name ->
            name

        FunctionType _ ->
            "function"
