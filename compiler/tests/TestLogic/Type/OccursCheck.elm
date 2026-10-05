module TestLogic.Type.OccursCheck exposing
    ( expectInfiniteTypeDetected
    , expectNoInfiniteTypes
    )

{-| Expectations for tests of the occurs check, the type checker's refusal of an
infinite type.

A type is infinite when a type variable would have to equal a type that
contains that same variable, as in `a = List a`: no finite type satisfies the
equation. Where the type checker runs the check is described in
`Compiler.Type.Solve` and `Compiler.Type.Occurs`.

  - `expectInfiniteTypeDetected name` runs the program through
    canonicalization and type checking with
    `TestLogic.Type.TypeCheckErrors.typeCheck`, and passes only when the
    solver reports an `InfiniteType` error for the variable `name`. A program
    that type checks, fails to canonicalize, or is rejected only with other
    errors fails it.
  - `expectNoInfiniteTypes` passes when the program gets through
    `TestLogic.TestPipeline.runToPostSolve` (canonicalization, type checking
    and PostSolve). On failure it lists the errors the program was rejected
    with.

`expectNoInfiniteTypes` does not walk the node types looking for a cycle: a
`Can.Type` is a finite tree, so a solved type that went through the conversion
to `Can.Type` cannot contain one. Acceptance is what that expectation checks.

-}

import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Expect
import TestLogic.TestPipeline as Pipeline
import TestLogic.Type.TypeCheckErrors as TypeCheckErrors


{-| Returns an expectation that passes when type checking `srcModule` reports
an infinite-type error for the variable `name`.
-}
expectInfiniteTypeDetected : Name -> Src.Module -> Expect.Expectation
expectInfiniteTypeDetected name srcModule =
    TypeCheckErrors.expectTypeErrorWhere
        ("an infinite-type error for `" ++ name ++ "`")
        (TypeCheckErrors.isInfiniteTypeFor name)
        srcModule


{-| Returns an expectation that passes when `srcModule` gets through PostSolve,
and otherwise fails naming the canonicalization or type errors.
-}
expectNoInfiniteTypes : Src.Module -> Expect.Expectation
expectNoInfiniteTypes srcModule =
    case Pipeline.runToPostSolve srcModule of
        Ok _ ->
            Expect.pass

        Err msg ->
            Expect.fail (msg ++ ": " ++ TypeCheckErrors.describeOutcome (TypeCheckErrors.typeCheck srcModule))
