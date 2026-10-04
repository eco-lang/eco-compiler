module TestLogic.Type.AnnotationEnforcement exposing
    ( expectAnnotationMismatchError
    , expectMatchingAnnotationSucceeds
    )

{-| Expectations for the tests that check the type checker enforces annotations:
a definition whose body agrees with its annotation must type-check, and one
whose body contradicts it must be rejected.

Each expectation takes a source module and canonicalizes it against the test
interfaces in `Compiler.Elm.Interface.Basic.testIfaces`. It then generates
constraints with node ids (`Compiler.Type.Constrain.Typed.Module.constrainWithIds`)
and solves them (`Compiler.Type.Solve.runWithIds`). Nothing after the solver
runs.

  - `expectMatchingAnnotationSucceeds` passes when the solver reports no type
    errors. Its failure message lists each type error by kind and start
    position.
  - `expectAnnotationMismatchError` passes when the solver reports at least one
    type error.

A module that fails to canonicalize fails both expectations, with a message
naming the first canonicalization error in the list.

Among what is not checked: that the error behind a passing
`expectAnnotationMismatchError` concerns the annotation, since any type error
passes it; which types or positions the error reports; and canonicalization
warnings, which are discarded.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Name exposing (Name)
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as CanError
import Compiler.Reporting.Error.Type as TypeError
import Compiler.Reporting.Result as Result
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.Solve as Solve
import Compiler.Type.Vars as Vars
import Dict
import Expect
import System.TypeCheck.IO as IO


{-| Returns an expectation that `srcModule` type-checks when `shouldSucceed` is
`True`, and that it fails to type-check when it is `False`. Any type error
satisfies `False`. A module that fails to canonicalize fails the expectation
either way.
-}
expectAnnotationEnforced : Src.Module -> Bool -> Expect.Expectation
expectAnnotationEnforced srcModule shouldSucceed =
    case canonicalizeModule srcModule of
        Err msg ->
            Expect.fail msg

        Ok modul ->
            let
                result =
                    IO.unsafePerformIO (runTypeCheck modul)
            in
            case ( result, shouldSucceed ) of
                ( Ok _, True ) ->
                    Expect.pass

                ( Err _, False ) ->
                    Expect.pass

                ( Ok _, False ) ->
                    Expect.fail "Expected annotation mismatch error but type checking succeeded"

                ( Err errors, True ) ->
                    let
                        errorList =
                            NE.toList errors
                    in
                    Expect.fail
                        ("Expected type checking to succeed but got errors: "
                            ++ (List.map typeErrorToString errorList |> String.join ", ")
                        )


{-| Returns an expectation that `srcModule` canonicalizes and then fails to
type-check. Any type error passes it, whether or not it concerns an annotation.
-}
expectAnnotationMismatchError : Src.Module -> Expect.Expectation
expectAnnotationMismatchError srcModule =
    expectAnnotationEnforced srcModule False


{-| Returns an expectation that `srcModule` canonicalizes and type-checks with no
errors.
-}
expectMatchingAnnotationSucceeds : Src.Module -> Expect.Expectation
expectMatchingAnnotationSucceeds srcModule =
    expectAnnotationEnforced srcModule True


{-| Canonicalizes `srcModule` against `Compiler.Elm.Interface.Basic.testIfaces`,
discarding warnings. On failure it returns a message naming only the first
error in the list.
-}
canonicalizeModule : Src.Module -> Result String Can.Module
canonicalizeModule srcModule =
    let
        result =
            Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule
    in
    case Result.run result of
        ( _, Err errors ) ->
            let
                errorList =
                    OneOrMore.destruct (::) errors

                firstError =
                    List.head errorList
                        |> Maybe.map canErrorToString
                        |> Maybe.withDefault "unknown"
            in
            Err ("Canonicalization failed: " ++ firstError)

        ( _, Ok modul ) ->
            Ok modul


{-| Builds the action that generates constraints for `modul` with node ids and
solves them, giving either the solver's type errors or its result.
-}
runTypeCheck :
    Can.Module
    ->
        IO.IO
            (Result
                (NE.Nonempty TypeError.Error)
                { annotations : Dict.Dict String (Can.Annotation Name)
                , nodeTypes : Array.Array (Maybe (Can.Type Name))
                , nodeVars : Array.Array (Maybe Vars.Variable)
                , annotationVars : Dict.Dict String Vars.Variable
                , solverState :
                    { cells : Array.Array Vars.PointCell
                    }
                }
            )
runTypeCheck modul =
    ConstrainTyped.constrainWithIds modul
        |> IO.andThen
            (\( constraint, nodeVars, _ ) ->
                Solve.runWithIds constraint nodeVars
            )


{-| Returns a one-line description of a type error: its constructor name, the
variable name for an infinite type, and the start of its region.
-}
typeErrorToString : TypeError.Error -> String
typeErrorToString error =
    case error of
        TypeError.BadExpr region _ _ _ ->
            "BadExpr at " ++ regionToString region

        TypeError.BadPattern region _ _ _ ->
            "BadPattern at " ++ regionToString region

        TypeError.InfiniteType region name _ ->
            "InfiniteType: " ++ name ++ " at " ++ regionToString region


{-| Returns a one-line description of a canonicalization error. Eight kinds are
described by constructor name and the name involved, with any module qualifier
for a missing variable or type and the expected and actual counts for
`BadArity`. Any other kind is rendered with `Debug.toString`.
-}
canErrorToString : CanError.Error -> String
canErrorToString error =
    case error of
        CanError.NotFoundVar _ maybeModule name _ ->
            "NotFoundVar: "
                ++ (maybeModule |> Maybe.map (\m -> m ++ ".") |> Maybe.withDefault "")
                ++ name

        CanError.NotFoundType _ maybeModule name _ ->
            "NotFoundType: "
                ++ (maybeModule |> Maybe.map (\m -> m ++ ".") |> Maybe.withDefault "")
                ++ name

        CanError.ImportNotFound _ name _ ->
            "ImportNotFound: " ++ name

        CanError.ImportExposingNotFound _ _ name _ ->
            "ImportExposingNotFound: " ++ name

        CanError.Shadowing name _ _ ->
            "Shadowing: " ++ name

        CanError.BadArity _ _ name expected actual ->
            "BadArity: " ++ name ++ " expected " ++ String.fromInt expected ++ " got " ++ String.fromInt actual

        CanError.AmbiguousType _ _ name _ _ ->
            "AmbiguousType: " ++ name

        CanError.AmbiguousVar _ _ name _ _ ->
            "AmbiguousVar: " ++ name

        _ ->
            Debug.toString error


{-| Returns the start of a region as `row:column`. The end is dropped.
-}
regionToString : A.Region -> String
regionToString (A.Region (A.Position startRow startCol) _) =
    String.fromInt startRow ++ ":" ++ String.fromInt startCol
