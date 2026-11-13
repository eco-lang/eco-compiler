module LayoutTests exposing (suite)

{-| The layout: every random graph is connected with the right number of edges, the tensor stress is
the plain one, relaxing lowers it and settles, and a pinned node stays put.
-}

import Expect
import Layout
import Test exposing (Test, describe, test)


near : Float -> Float -> Float -> Bool
near tol a b =
    abs (a - b) <= tol * max 1 (abs a)


settle : Int -> Layout.State -> ( Layout.State, Int )
settle n s =
    let
        ( next, _ ) =
            Layout.relax Nothing s
    in
    if n >= 400 || Layout.settled s next then
        ( next, n )

    else
        settle (n + 1) next


suite : Test
suite =
    describe "Layout"
        [ test "random graphs are connected, with 19 + 7 distinct edges and no loops" <|
            \_ ->
                let
                    ok seed =
                        let
                            s =
                                Layout.random seed

                            es =
                                s.net.edges

                            distinct =
                                List.all (\( a, b ) -> List.length (List.filter (\( p, q ) -> ( p, q ) == ( a, b ) || ( p, q ) == ( b, a )) es) == 1) es
                        in
                        List.length es == 26 && distinct && List.all (\( a, b ) -> a /= b) es && List.all (\d -> d >= 0) s.net.distances
                in
                Expect.equal (List.map ok (List.range 1 20)) (List.repeat 20 True)
        , test "different seeds give different graphs" <|
            \_ ->
                Expect.notEqual (Layout.random 1).net.edges (Layout.random 2).net.edges
        , test "the tensor stress is the plain one" <|
            \_ ->
                let
                    s =
                        Layout.random 3

                    ( _, st ) =
                        Layout.relax Nothing s
                in
                Expect.equal (near 1.0e-10 (Layout.stress s.net s.positions) st) True
        , test "relaxing lowers the stress and settles" <|
            \_ ->
                let
                    s =
                        Layout.random 4

                    ( final, runs ) =
                        settle 0 s
                in
                Expect.equal ( Layout.stress final.net final.positions < 0.5 * Layout.stress s.net s.positions, runs < 400 ) ( True, True )
        , test "a pinned node stays put" <|
            \_ ->
                let
                    ( after, _ ) =
                        Layout.relax (Just 7) Layout.init
                in
                Expect.equal (List.drop 7 after.positions |> List.head) (List.drop 7 Layout.init.positions |> List.head)
        ]
