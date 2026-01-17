module Compiler.Type.AnnotationEnforcement exposing
    ( expectAnnotationMismatchError
    , expectMatchingAnnotationSucceeds
    )

{-| Test logic for invariant TYPE\_006: Annotations are enforced, not ignored.

For expressions with explicit annotations:

  - Generate matching and intentionally mismatched annotations.
  - Ensure constraints require equality between annotated and inferred types.
  - Any mismatch must produce a Type.Error (BadTypes) and not be silently coerced.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as CanError
import Compiler.Reporting.Error.Type as TypeError
import Compiler.Reporting.Result as Result
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.Solve as Solve
import Data.Map exposing (Dict)
import Expect
import System.TypeCheck.IO as IO


{-| Expect type checking to enforce annotations (success for matching, error for mismatch).
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


{-| Expect type checking to fail due to annotation mismatch.
-}
expectAnnotationMismatchError : Src.Module -> Expect.Expectation
expectAnnotationMismatchError srcModule =
    expectAnnotationEnforced srcModule False


{-| Expect type checking to succeed with matching annotation.
-}
expectMatchingAnnotationSucceeds : Src.Module -> Expect.Expectation
expectMatchingAnnotationSucceeds srcModule =
    expectAnnotationEnforced srcModule True


{-| Canonicalize a source module.
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


{-| Run type checking on a canonical module.
-}
runTypeCheck : Can.Module -> IO.IO (Result (NE.Nonempty TypeError.Error) { annotations : Dict String String Can.Annotation, nodeTypes : Dict Int Int Can.Type })
runTypeCheck modul =
    ConstrainTyped.constrainWithIds modul
        |> IO.andThen
            (\( constraint, nodeVars ) ->
                Solve.runWithIds constraint nodeVars
            )


{-| Convert a type error to a string.
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


{-| Convert a canonicalization error to a string.
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


{-| Convert a region to a string.
-}
regionToString : A.Region -> String
regionToString (A.Region (A.Position startRow startCol) _) =
    String.fromInt startRow ++ ":" ++ String.fromInt startCol
