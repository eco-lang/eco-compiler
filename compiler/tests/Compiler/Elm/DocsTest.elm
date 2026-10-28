module Compiler.Elm.DocsTest exposing (suite)

{-| Regression test for `Compiler.Elm.Docs.checkNames`, pinning a bug fixed
2026-10-28 (plans/review-bug-triage-fixes.md, Part 5).

`checkNames` folds the exposed names and the `@docs` names with `Dict.merge`,
but its step functions (`loneExport`, `checkBoth`, `loneDoc`) ignore the
accumulator, so only the last name in key order decides the outcome. Here `a`
is exposed but not on `@docs`, and `b` is on `@docs` but not exposed; `z`, the
last name, is fine, so the name problems are lost. The values have no
annotations, so with the bug `fromModule` goes on to `checkDefs` and returns a
`DefProblems` (NoAnnotation) instead of the expected `NameProblems`.

The module is parsed and canonicalized as a module of elm/core so that it gets
no default imports (`Basic.testIfaces` lacks `Debug`, `Platform`, ...).

-}

import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Elm.Docs as Docs
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Elm.Package as Pkg
import Compiler.PackageCompilation as PC
import Compiler.Reporting.Error.Docs as EDocs
import Compiler.Reporting.Result as RResult
import Expect
import Test exposing (Test)


source : String
source =
    """module Example exposing (a, z)

{-| Example.

@docs b, z

-}


{-| a -}
a =
    1


{-| z -}
z =
    2
"""


suite : Test
suite =
    Test.describe "Compiler.Elm.Docs.fromModule name checks"
        [ Test.test "an earlier @docs/exposing disagreement is reported even when the last name is fine" <|
            \_ ->
                case PC.parseModule Pkg.core source of
                    Err _ ->
                        Expect.fail "parse failed"

                    Ok srcModule ->
                        case Tuple.second (RResult.run (Canonicalize.canonicalize Pkg.core Basic.testIfaces srcModule)) of
                            Err _ ->
                                Expect.fail "canonicalization failed"

                            Ok canModule ->
                                case Docs.fromModule canModule of
                                    Err (EDocs.NameProblems _) ->
                                        Expect.pass

                                    Err _ ->
                                        Expect.fail "the @docs/exposing disagreement on `a` and `b` was lost: fromModule went on to check the definitions"

                                    Ok _ ->
                                        Expect.fail "fromModule succeeded although `a` is not on @docs and `b` is not exposed"
        ]
