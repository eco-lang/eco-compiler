module Compiler.Type.Constrain.Typed.ExpressionTest exposing (suite)

{-| Regression test for a suspected bug in
`Compiler.Type.Constrain.Typed.Expression.constrainLetSpine` (S2 list,
Type/Constrain/Typed/Expression.elm lines 608 and 658).

EXPECTED TO FAIL until the bug is fixed.

The let spine constrains the innermost `let` body against `NoExpectation` of a
fresh variable and only equates that variable with the outer expectation in
`applyLetFrame`, at the whole `let`'s region and with category `Lambda`. So a
`let` body that does not match the annotation, as in

    f : Int
    f =
        let
            x =
                1
        in
        "s"

is reported at the whole `let` as "an anonymous function", instead of at the
body `"s"` with category `String` (as the non-spine path, and Elm, report it).
Nested `if`/`case` bodies likewise lose their `TypedIfBranch` /
`TypedCaseBranch` expectations.

The check: the one type error is a `BadExpr` of category `String`.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (makeModule, unitExpr)
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.NonEmptyList as NE
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Parse.Module as M
import Compiler.Reporting.Error.Type as ErrT
import Compiler.Reporting.Result as RResult
import Compiler.Type.Constrain.Typed.Module as ConstrainTyped
import Compiler.Type.Solve as Solve
import Expect
import System.TypeCheck.IO as IO
import Test exposing (Test)


suite : Test
suite =
    Test.test "Regression: a let body that mismatches its annotation is reported at the body" <|
        \_ ->
            case typeErrors source of
                Err msg ->
                    Expect.fail msg

                Ok [ ErrT.BadExpr _ category _ _ ] ->
                    Expect.equal ErrT.String category

                Ok errs ->
                    Expect.fail ("expected one BadExpr, got " ++ Debug.toString errs)


source : String
source =
    """module Test exposing (..)


f : Int
f =
    let
        x =
            1
    in
    "s"
"""


parse : String -> Result String Src.Module
parse src =
    case M.fromByteString M.Application src of
        Ok (Src.Module m) ->
            let
                (Src.Module template) =
                    makeModule "unused" unitExpr
            in
            Ok (Src.Module { m | imports = template.imports })

        Err _ ->
            Err "fixture failed to parse"


typeErrors : String -> Result String (List ErrT.Error)
typeErrors src =
    case parse src |> Result.map (Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces >> RResult.run >> Tuple.second) of
        Err msg ->
            Err msg

        Ok (Err _) ->
            Err "fixture failed to canonicalize"

        Ok (Ok canonical) ->
            ConstrainTyped.constrainWithIds canonical
                |> IO.andThen (\( constraint, nodeVars, _ ) -> Solve.runWithIds constraint nodeVars)
                |> IO.map
                    (\result ->
                        case result of
                            Ok _ ->
                                Err "no type error"

                            Err (NE.Nonempty e rest) ->
                                Ok (e :: rest)
                    )
                |> IO.unsafePerformIO
