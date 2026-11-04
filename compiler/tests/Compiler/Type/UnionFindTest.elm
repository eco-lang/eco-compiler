module Compiler.Type.UnionFindTest exposing (suite)

{-| Builds a union-find class in which one point is two links from its root,
then sets that point's descriptor and joins the point with itself, through
`Compiler.Type.UnionFind`.

Four fresh points `a`, `b`, `c` and `d` are joined as `a` with `b` and `c` with
`d`, which gives two classes of weight 2 rooted at `a` and `c`. Joining `a` with
`c` puts `c` under `a`, because on equal weights the second root goes under
the first, so `d` links to `c`, which links to `a`. Setting `d`'s descriptor
then has to follow the longer path, and joining `d` with itself only replaces
the class's descriptor. The type checker compresses paths as it reads them, so
its programs do not reach either case, and the test calls the module directly.
The group label contains `coverage run`, so that the coverage loop's quick runs
count it.

-}

import Compiler.IR.Typed.TypeVars as Vars exposing (Content(..), Mark(..))
import Compiler.Type.State.IO as IO exposing (IO)
import Compiler.Type.UnionFind as UF
import Expect
import Test exposing (Test)


{-| The group "coverage run: union-find long paths".
-}
suite : Test
suite =
    Test.describe "coverage run: union-find long paths"
        [ Test.test "a point two links from its root is set and joined with itself" <|
            \_ ->
                IO.unsafePerformIO program
                    |> Expect.equal ( Just "set", Just "self", True )
        ]


program : IO ( Maybe String, Maybe String, Bool )
program =
    UF.fresh (descriptor "a")
        |> IO.andThen
            (\a ->
                UF.fresh (descriptor "b")
                    |> IO.andThen
                        (\b ->
                            UF.fresh (descriptor "c")
                                |> IO.andThen
                                    (\c ->
                                        UF.fresh (descriptor "d")
                                            |> IO.andThen (\d -> joined a b c d)
                                    )
                        )
            )


joined : Vars.Point -> Vars.Point -> Vars.Point -> Vars.Point -> IO ( Maybe String, Maybe String, Bool )
joined a b c d =
    union a b "ab"
        |> IO.andThen (\_ -> union c d "cd")
        |> IO.andThen (\_ -> union a c "ac")
        |> IO.andThen (\_ -> UF.set d (descriptor "set"))
        |> IO.andThen (\_ -> UF.get b)
        |> IO.andThen
            (\afterSet ->
                union d d "self"
                    |> IO.andThen (\_ -> UF.get a)
                    |> IO.andThen
                        (\afterSelf ->
                            UF.equivalent b d
                                |> IO.map (\same -> ( nameOf afterSet, nameOf afterSelf, same ))
                        )
            )


union : Vars.Point -> Vars.Point -> String -> IO ()
union p1 p2 name s =
    ( UF.unionS p1 p2 (descriptor name) s, () )


descriptor : String -> Vars.Descriptor
descriptor name =
    IO.makeDescriptor (FlexVar (Just name)) 0 (Mark 0) Nothing


nameOf : Vars.Descriptor -> Maybe String
nameOf desc =
    case desc.content of
        FlexVar name ->
            name

        _ ->
            Nothing
