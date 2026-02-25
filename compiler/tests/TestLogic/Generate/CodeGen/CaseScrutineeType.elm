module TestLogic.Generate.CodeGen.CaseScrutineeType exposing (expectCaseScrutineeType)

{-| Test logic for CGEN\_037: Case Scrutinee Type Agreement invariant.

`eco.case` scrutinee is `i1` only for boolean cases; otherwise `!eco.value`.

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


{-| Verify that case scrutinee type invariants hold for a source module.
-}
expectCaseScrutineeType : Src.Module -> Expectation
expectCaseScrutineeType srcModule =
    case runToMlir srcModule of
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
    in
    List.filterMap checkCaseScrutinee caseOps


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
                    -- Int cases require i64 scrutinee
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
                    -- Char cases require i16 scrutinee (eco.char)
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
                    -- Constructor cases require eco.value scrutinee
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
                    -- String cases require eco.value scrutinee
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
                    -- Boolean cases require i1 scrutinee
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
                    -- Unknown case_kind, no validation
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
