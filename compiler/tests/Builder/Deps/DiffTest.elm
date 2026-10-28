module Builder.Deps.DiffTest exposing (suite)

{-| Regression test for Builder.Deps.Diff.isEquivalentUnion: the union's type
variable lists are only compared through constructor arguments, so a union
whose (exposed) constructors carry no arguments never compares them. Changing
opaque `type Foo a` to `type Foo a b` is judged a PATCH though every `Foo x`
annotation in user code breaks.

EXPECTED TO FAIL until the bug is fixed.

-}

import Builder.Deps.Diff as Diff
import Compiler.Elm.Docs as Docs
import Compiler.Elm.Magnitude as M
import Dict
import Expect
import Test exposing (Test, describe, test)


docsWith : Docs.Union -> Docs.Documentation
docsWith union =
    Dict.singleton "M"
        (Docs.Module
            { name = "M"
            , comment = ""
            , unions = Dict.singleton "Foo" union
            , aliases = Dict.empty
            , values = Dict.empty
            , binops = Dict.empty
            }
        )


suite : Test
suite =
    describe "Builder.Deps.Diff union type variables"
        [ test "opaque type gaining a type variable is MAJOR" <|
            \_ ->
                Diff.diff (docsWith (Docs.Union "" [ "a" ] [])) (docsWith (Docs.Union "" [ "a", "b" ] []))
                    |> Diff.toMagnitude
                    |> Expect.equal M.MAJOR
        , test "union of nullary constructors gaining a type variable is MAJOR" <|
            \_ ->
                Diff.diff (docsWith (Docs.Union "" [ "a" ] [ ( "A", [] ) ])) (docsWith (Docs.Union "" [ "a", "b" ] [ ( "A", [] ) ]))
                    |> Diff.toMagnitude
                    |> Expect.equal M.MAJOR
        ]
