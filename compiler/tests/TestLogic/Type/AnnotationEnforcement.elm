module TestLogic.Type.AnnotationEnforcement exposing
    ( expectAnnotationMismatchError
    , expectMatchingAnnotationSucceeds
    )

{-| Expectations for the tests that check the type checker enforces annotations:
a definition whose body agrees with its annotation must type-check, and one
whose body contradicts it must be rejected because of that annotation.

Each expectation takes a source module and runs it through
`TestLogic.Type.TypeCheckErrors.typeCheck`: canonicalization against the test
interfaces in `Compiler.Elm.Interface.Basic.testIfaces`, constraint generation
with node ids and the solver. Nothing after the solver runs.

  - `expectMatchingAnnotationSucceeds` passes when the solver reports no type
    errors.
  - `expectAnnotationMismatchError name` passes when the solver reports at
    least one error whose expected type came from the annotation of `name`
    (`FromAnnotation name`), or a pattern error on one of that annotation's
    arguments (`PTypedArg name`). A module rejected only with other errors
    fails it.

A module that fails to canonicalize fails both expectations. Every failure
message lists the errors by kind, position, category and the source of the
expected type.

Among what is not checked: which types or positions the error reports, and
canonicalization warnings, which are discarded.

-}

import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Expect
import TestLogic.Type.TypeCheckErrors as TypeCheckErrors


{-| Returns an expectation that `srcModule` canonicalizes and is rejected with
at least one type error that comes from the annotation of the definition
`name`.
-}
expectAnnotationMismatchError : Name -> Src.Module -> Expect.Expectation
expectAnnotationMismatchError name srcModule =
    TypeCheckErrors.expectTypeErrorWhere
        ("a type error from the annotation of `" ++ name ++ "`")
        (TypeCheckErrors.isAnnotationMismatch name)
        srcModule


{-| Returns an expectation that `srcModule` canonicalizes and type-checks with no
errors.
-}
expectMatchingAnnotationSucceeds : Src.Module -> Expect.Expectation
expectMatchingAnnotationSucceeds srcModule =
    case TypeCheckErrors.typeCheck srcModule of
        TypeCheckErrors.TypeChecks ->
            Expect.pass

        outcome ->
            Expect.fail ("Expected type checking to succeed, but " ++ TypeCheckErrors.describeOutcome outcome)
