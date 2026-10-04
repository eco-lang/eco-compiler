module TestLogic.Type.UnificationErrors exposing
    ( expectNoTypeErrors
    , expectTypeMismatchError
    )

{-| Expectations that the type checker rejects a source module with a type
mismatch, or accepts it with no type errors.

Each expectation canonicalizes its `Src.Module` as package `eco/example`
against the mock interfaces of `Compiler.Elm.Interface.Basic.testIfaces`, then
type checks the result with the typed pipeline's constraint generator,
`Compiler.Type.Constrain.Typed.Module.constrainWithIds`, and solver,
`Compiler.Type.Solve.runWithIds`. A module that fails to canonicalize fails
either expectation. The message describes only the first canonicalization
error, and gives detail only for a `NotFoundVar`.

A _type mismatch_ is a `BadExpr` or `BadPattern` error: an expression or a
pattern whose type conflicts with the type its context requires. The third
kind of type error, `InfiniteType`, is not a mismatch.

  - `expectTypeMismatchError` passes when type checking fails and at least one
    of the errors is a mismatch. It fails when type checking succeeds, or when
    every error is an `InfiniteType`. It is there to catch a solver that lets
    a failed unification pass, and so accepts an ill-typed program.
  - `expectNoTypeErrors` passes when type checking succeeds, and fails on any
    type error. It is there to catch a solver that reports type errors for a
    well-typed module.

Among what is not checked: where a mismatch is or which types conflict, since
only the error's constructor is looked at; and the steps after solving, such
as `PostSolve` and the pattern exhaustiveness check, which are not run.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.TypeVars as Vars
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
import Compiler.Type.Error as T
import Compiler.Type.Solve as Solve
import Dict
import Expect
import System.TypeCheck.IO as IO


{-| Passes when type checking `srcModule` fails with at least one `BadExpr` or
`BadPattern` error among its errors. Fails when canonicalization fails, when
type checking succeeds, or when every error is an `InfiniteType`; the last case
lists the errors in the failure message.
-}
expectTypeMismatchError : Src.Module -> Expect.Expectation
expectTypeMismatchError srcModule =
    case canonicalizeModule srcModule of
        Err msg ->
            Expect.fail msg

        Ok modul ->
            let
                result =
                    IO.unsafePerformIO (runTypeCheck modul)
            in
            case result of
                Err errors ->
                    let
                        errorList =
                            NE.toList errors

                        hasMismatch =
                            List.any isMismatchError errorList
                    in
                    if hasMismatch then
                        Expect.pass

                    else
                        Expect.fail
                            ("Expected a type mismatch error but got: "
                                ++ (List.map typeErrorToString errorList |> String.join ", ")
                            )

                Ok _ ->
                    Expect.fail "Expected a type mismatch error but type checking succeeded"


{-| Passes when `srcModule` canonicalizes and type checks with no errors.
Fails when canonicalization fails, or on any type error, listing every type
error in the message.
-}
expectNoTypeErrors : Src.Module -> Expect.Expectation
expectNoTypeErrors srcModule =
    case canonicalizeModule srcModule of
        Err msg ->
            Expect.fail msg

        Ok modul ->
            let
                result =
                    IO.unsafePerformIO (runTypeCheck modul)
            in
            case result of
                Err errors ->
                    let
                        errorList =
                            NE.toList errors
                    in
                    Expect.fail
                        ("Expected no type errors but got: "
                            ++ (List.map typeErrorToString errorList |> String.join ", ")
                        )

                Ok _ ->
                    Expect.pass


{-| Returns whether `error` is a type mismatch: `True` for `BadExpr` and
`BadPattern`, `False` for `InfiniteType`.
-}
isMismatchError : TypeError.Error -> Bool
isMismatchError error =
    case error of
        TypeError.BadExpr _ _ _ _ ->
            True

        TypeError.BadPattern _ _ _ _ ->
            True

        TypeError.InfiniteType _ _ _ ->
            False


{-| Canonicalizes `srcModule` as package `eco/example` against
`Basic.testIfaces`. Warnings are dropped. On failure the message describes
only the first error, and gives detail only for a `NotFoundVar`.
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


{-| Type checks `modul`: generates its constraints with
`ConstrainTyped.constrainWithIds`, which also returns the solver variable of
each expression and pattern id, and solves them with `Solve.runWithIds`. The
result is the errors or the success record of `Solve.runWithIds`.
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


{-| Renders `error` as a one-line summary: its constructor and the start of its
region, with the actual type for a `BadExpr`, in the short form `tTypeToString`
gives, and the name of the variable whose type is infinite for an
`InfiniteType`. The expected type is never printed, although a `BadExpr`
summary ends with the words "vs expected".
-}
typeErrorToString : TypeError.Error -> String
typeErrorToString error =
    case error of
        TypeError.BadExpr region _ actualType _ ->
            "BadExpr at "
                ++ regionToString region
                ++ ": "
                ++ tTypeToString actualType
                ++ " vs expected"

        TypeError.BadPattern region _ _ _ ->
            "BadPattern at " ++ regionToString region

        TypeError.InfiniteType region name _ ->
            "InfiniteType: " ++ name ++ " at " ++ regionToString region


{-| Renders a canonicalization error for a failure message. Only `NotFoundVar`
is described, as the name that was not found with its qualifier if it had one;
every other error gives the same generic text.
-}
canErrorToString : CanError.Error -> String
canErrorToString error =
    case error of
        CanError.NotFoundVar _ maybeModule name _ ->
            "NotFoundVar: "
                ++ (maybeModule |> Maybe.map (\m -> m ++ ".") |> Maybe.withDefault "")
                ++ name

        _ ->
            "Other canonicalization error"


{-| Renders the start of a region as `row:column`. The end is ignored.
-}
regionToString : A.Region -> String
regionToString (A.Region (A.Position startRow startCol) (A.Position _ _)) =
    String.fromInt startRow ++ ":" ++ String.fromInt startCol


{-| Renders a short form of an error type: the bare name of a named type,
without its module or arguments; the name of a flexible or rigid variable that
is not constrained; or `()` for unit. Every other type, including functions,
records, tuples, aliases and constrained variables such as `number`, renders
as `...`.
-}
tTypeToString : T.Type -> String
tTypeToString tType =
    case tType of
        T.Type _ name _ ->
            name

        T.FlexVar name ->
            name

        T.RigidVar name ->
            name

        T.Unit ->
            "()"

        _ ->
            "..."
