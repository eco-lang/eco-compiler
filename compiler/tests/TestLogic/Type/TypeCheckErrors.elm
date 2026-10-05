module TestLogic.Type.TypeCheckErrors exposing
    ( Outcome(..)
    , typeCheck
    , describeOutcome, describeError
    , isAnnotationMismatch, isInfiniteTypeFor, isCallArgMismatch
    , expectTypeErrorWhere
    )

{-| Runs a test program through canonicalization and type checking and keeps
the errors themselves, so that a rejection test can check _which_ error the
program was rejected with.

`TestLogic.TestPipeline.runToTypeCheck` reports a failure only as a count of
errors, and it reports a canonicalization failure and a type error with the
same `Err`, so a rejection test built on it passes for a program rejected for
any reason at all. The stages here are the same ones it runs: canonicalization
as the package `eco/example` against `Compiler.Elm.Interface.Basic.testIfaces`,
then constraint generation with node ids
(`Compiler.Type.Constrain.Typed.Module.constrainWithIds`) and
`Compiler.Type.Solve.runWithIds`. Nothing after the solver runs.

@docs Outcome
@docs typeCheck
@docs describeOutcome, describeError
@docs isAnnotationMismatch, isInfiniteTypeFor, isCallArgMismatch
@docs expectTypeErrorWhere

-}

import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Data.NonEmptyList as NE
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as CanError
import Compiler.Reporting.Error.Type as TypeError
import Compiler.Reporting.Result as RResult
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.Solve as Solve
import Expect
import System.TypeCheck.IO as IO


{-| How far a program got: it failed to canonicalize, with the canonicalization
errors; it canonicalized and the solver reported type errors, in the order the
solver returned them; or it type checked.
-}
type Outcome
    = CanonicalizationFailed (List CanError.Error)
    | TypeErrors (List TypeError.Error)
    | TypeChecks


{-| Canonicalizes and type checks `srcModule`, keeping the errors.
-}
typeCheck : Src.Module -> Outcome
typeCheck srcModule =
    case RResult.run (Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces srcModule) of
        ( _, Err errors ) ->
            CanonicalizationFailed (OneOrMore.destruct (::) errors)

        ( _, Ok canonical ) ->
            let
                result =
                    ConstrainTyped.constrainWithIds canonical
                        |> IO.andThen (\( constraint, nodeVars, _ ) -> Solve.runWithIds constraint nodeVars)
                        |> IO.unsafePerformIO
            in
            case result of
                Ok _ ->
                    TypeChecks

                Err errors ->
                    TypeErrors (NE.toList errors)


{-| A one-line description of an outcome, listing every error with
`describeError`, or the canonicalization errors by constructor.
-}
describeOutcome : Outcome -> String
describeOutcome outcome =
    case outcome of
        CanonicalizationFailed errors ->
            "canonicalization failed: " ++ String.join "; " (List.map canErrorName errors)

        TypeErrors errors ->
            "type errors: " ++ String.join "; " (List.map describeError errors)

        TypeChecks ->
            "the program type checked"


{-| A one-line description of a type error: its kind, its start position, its
category and where its expected type came from. Types are not printed.
-}
describeError : TypeError.Error -> String
describeError error =
    case error of
        TypeError.BadExpr region category _ expected ->
            "BadExpr at "
                ++ regionToString region
                ++ " ("
                ++ Debug.toString category
                ++ ", expected "
                ++ describeExpected expected
                ++ ")"

        TypeError.BadPattern region category _ expected ->
            "BadPattern at "
                ++ regionToString region
                ++ " ("
                ++ Debug.toString category
                ++ ", expected "
                ++ (case expected of
                        TypeError.PNoExpectation _ ->
                            "with no context"

                        TypeError.PFromContext _ context _ ->
                            "from " ++ Debug.toString context
                   )
                ++ ")"

        TypeError.InfiniteType region name _ ->
            "InfiniteType " ++ name ++ " at " ++ regionToString region


{-| True for an expression error whose expected type came from the annotation
of the definition named `name`, or for a pattern error on an argument of that
definition's annotation.
-}
isAnnotationMismatch : Name -> TypeError.Error -> Bool
isAnnotationMismatch name error =
    case error of
        TypeError.BadExpr _ _ _ (TypeError.FromAnnotation annotated _ _ _) ->
            annotated == name

        TypeError.BadPattern _ _ _ (TypeError.PFromContext _ (TypeError.PTypedArg annotated _) _) ->
            annotated == name

        _ ->
            False


{-| True for an infinite-type error on the variable named `name`.
-}
isInfiniteTypeFor : Name -> TypeError.Error -> Bool
isInfiniteTypeFor name error =
    case error of
        TypeError.InfiniteType _ errorName _ ->
            errorName == name

        _ ->
            False


{-| True for an expression error on the call argument at zero-based position
`index`, whatever the function is called.
-}
isCallArgMismatch : Int -> TypeError.Error -> Bool
isCallArgMismatch index error =
    case error of
        TypeError.BadExpr _ _ _ (TypeError.FromContext _ (TypeError.CallArg _ argIndex) _) ->
            Index.toMachine argIndex == index

        _ ->
            False


{-| Passes when `srcModule` canonicalizes and the solver reports at least one
type error satisfying `wanted`. Fails, naming every error, when the program
fails to canonicalize, type checks, or is rejected only with other errors.
`what` describes the wanted error in the failure message.
-}
expectTypeErrorWhere : String -> (TypeError.Error -> Bool) -> Src.Module -> Expect.Expectation
expectTypeErrorWhere what wanted srcModule =
    let
        outcome =
            typeCheck srcModule
    in
    case outcome of
        TypeErrors errors ->
            if List.any wanted errors then
                Expect.pass

            else
                Expect.fail ("Expected " ++ what ++ ", but got " ++ describeOutcome outcome)

        _ ->
            Expect.fail ("Expected " ++ what ++ ", but " ++ describeOutcome outcome)



-- ====== HELPERS ======


describeExpected : TypeError.Expected a -> String
describeExpected expected =
    case expected of
        TypeError.NoExpectation _ ->
            "with no context"

        TypeError.FromContext _ context _ ->
            "from " ++ contextName context

        TypeError.FromAnnotation name _ subContext _ ->
            "from the annotation of " ++ name ++ " (" ++ Debug.toString subContext ++ ")"


{-| The constructor of a context, with its position or name where it has one.
`RecordUpdateKeys` carries canonical expressions, which are not printed.
-}
contextName : TypeError.Context -> String
contextName context =
    case context of
        TypeError.RecordUpdateKeys _ ->
            "RecordUpdateKeys"

        TypeError.RecordAccess _ _ _ field ->
            "RecordAccess " ++ field

        _ ->
            Debug.toString context


canErrorName : CanError.Error -> String
canErrorName error =
    Debug.toString error
        |> String.words
        |> List.head
        |> Maybe.withDefault "?"


regionToString : A.Region -> String
regionToString (A.Region (A.Position row col) _) =
    String.fromInt row ++ ":" ++ String.fromInt col
