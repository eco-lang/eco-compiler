module TestLogic.Generate.CodeGen.CaseKindScrutinee exposing
    ( expectCaseKindScrutinee
    , checkCaseKindScrutinee
    )

{-| Test logic for CGEN_043: Case Kind Scrutinee Type Agreement invariant.

`eco.case` scrutinee representation and `case_kind` must agree:

  - `case_kind="bool"` requires `i1` scrutinee
  - `case_kind="int"` requires `i64` scrutinee
  - `case_kind="chr"` requires `i16` (ECO char) scrutinee
  - `case_kind="ctor"` requires `!eco.value` scrutinee
  - `case_kind="str"` requires `!eco.value` scrutinee

@docs expectCaseKindScrutinee, checkCaseKindScrutinee

-}

import Compiler.AST.Source as Src
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , findOpsNamed
        , getStringAttr
        , typesMatch
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))


{-| Verify that case kind scrutinee type invariants hold for a source module.
-}
expectCaseKindScrutinee : Src.Module -> Expectation
expectCaseKindScrutinee srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseKindScrutinee mlirModule)


{-| Check case kind scrutinee type invariants.
-}
checkCaseKindScrutinee : MlirModule -> List Violation
checkCaseKindScrutinee mlirModule =
    let
        caseOps =
            findOpsNamed "eco.case" mlirModule

        violations =
            List.filterMap checkCaseOp caseOps
    in
    violations


checkCaseOp : MlirOp -> Maybe Violation
checkCaseOp op =
    let
        maybeCaseKind =
            getStringAttr "case_kind" op

        maybeOperandTypes =
            extractOperandTypes op
    in
    case ( maybeCaseKind, maybeOperandTypes ) of
        ( Nothing, _ ) ->
            Nothing

        ( _, Nothing ) ->
            Nothing

        ( _, Just [] ) ->
            Nothing

        ( Just caseKind, Just (scrutineeType :: _) ) ->
            validateCaseKind caseKind scrutineeType op


validateCaseKind : String -> MlirType -> MlirOp -> Maybe Violation
validateCaseKind caseKind scrutineeType op =
    let
        ( expectedType, expectedDesc ) =
            case caseKind of
                "bool" ->
                    ( Just I1, "i1" )

                "int" ->
                    ( Just I64, "i64" )

                "chr" ->
                    ( Just I16, "i16 (ECO char)" )

                "ctor" ->
                    ( Just (NamedStruct "eco.value"), "eco.value" )

                "str" ->
                    ( Just (NamedStruct "eco.value"), "eco.value" )

                _ ->
                    ( Nothing, "unknown" )
    in
    case expectedType of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "Unknown case_kind='" ++ caseKind ++ "'"
                }

        Just expected ->
            if typesMatch scrutineeType expected then
                Nothing

            else
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "case_kind='"
                            ++ caseKind
                            ++ "' requires "
                            ++ expectedDesc
                            ++ " scrutinee, got "
                            ++ typeToString scrutineeType
                    }


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
