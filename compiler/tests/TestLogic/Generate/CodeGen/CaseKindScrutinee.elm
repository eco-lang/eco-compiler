module TestLogic.Generate.CodeGen.CaseKindScrutinee exposing (expectCaseKindScrutinee)

{-| An `eco.case` op's kind of dispatch and the type of the value it dispatches
on are given to it separately, and nothing in `Mlir.Mlir` makes them agree. This
module checks that they do in the MLIR the code generator produces.

An `eco.case` branches on its operand, the _scrutinee_. Its `case_kind` string
attribute, the _case kind_, says what sort of value the scrutinee is. The
scrutinee's type is read from the first type in the op's `_operand_types`
attribute, as `TestLogic.Generate.CodeGen.Invariants` describes. The two agree
when the type is exactly the one the case kind requires:

  - `bool` requires `i1`.
  - `int` requires `i64`.
  - `chr` requires `i16`, the type of an unboxed Char.
  - `ctor` and `str` require `!eco.value`, the type of a boxed value.

A case kind outside this list is itself a violation.

`expectCaseKindScrutinee` takes the program to check from its caller and
compiles it with `TestLogic.TestPipeline.runToMlir`, so the program must be one
that function accepts. The expectation it returns establishes:

  - The program compiles through `runToMlir` without an error.
  - Every `eco.case` in the generated module, at any depth, whose `case_kind`
    is a string or a symbol reference and whose `_operand_types` holds at least
    one type names a case kind in the list above and has a scrutinee of exactly
    the type that case kind requires.

Among what is not tested: an `eco.case` whose `case_kind` is missing or is
neither a string nor a symbol reference, or whose `_operand_types` holds no
type, which is skipped; any operand type after the first; the case's tags and
the types of its results.

@docs expectCaseKindScrutinee

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
        , typesMatch
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR with
`TestLogic.TestPipeline.runToMlir` and passes when every `eco.case` in the
result has a scrutinee of the type its case kind requires: `i1` for `bool`,
`i64` for `int`, `i16` for `chr`, and `!eco.value` for `ctor` and `str`.

An `eco.case` naming any other case kind is a violation. One whose `case_kind`
is missing or is neither a string nor a symbol reference, or whose
`_operand_types` holds no type, is not checked. The expectation fails with a
message starting `Compilation failed:` if `runToMlir` returns an error, and
otherwise as `violationsToExpectation` describes.

-}
expectCaseKindScrutinee : Src.Module -> Expectation
expectCaseKindScrutinee srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCaseKindScrutinee mlirModule)


{-| Returns one violation for each `eco.case` in `mlirModule`, at any depth,
whose case kind and scrutinee type disagree, in the order the module's ops are
walked.
-}
checkCaseKindScrutinee : MlirModule -> List Violation
checkCaseKindScrutinee mlirModule =
    let
        caseOps =
            findOpsNamed "eco.case" mlirModule
    in
    List.filterMap checkCaseOp caseOps


{-| Returns the violation `op` commits, if any. An op whose `case_kind` is
missing or is neither a string nor a symbol reference, or whose
`_operand_types` holds no type, is not checked and gives `Nothing`; otherwise
the first type in `_operand_types` is taken as the scrutinee's.
-}
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


{-| Returns a violation against `op` when `scrutineeType` is not exactly the type
`caseKind` requires, with a message naming both types, or when `caseKind` is
not one of `bool`, `int`, `chr`, `ctor` and `str`. Returns `Nothing` when they
agree.
-}
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


{-| Returns the name a violation message gives `t`: the MLIR spelling of an
integer or float type, a named struct's name without the leading `!` (so
`eco.value`), and `function` for any function type.
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
