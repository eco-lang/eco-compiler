module Parse.PrimitivesTests exposing (suite)

import Compiler.Parse.Primitives as P
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Parse.Primitives"
        [ Test.describe "getCharWidth"
            [ (\_ ->
                P.getCharWidth 'a'
                    |> Expect.equal 1
              )
                |> Test.test "Latin Small Letter A"
            , (\_ ->
                P.getCharWidth 'Z'
                    |> Expect.equal 1
              )
                |> Test.test "Latin Capital Letter Z"
            , (\_ ->
                P.getCharWidth '…'
                    |> Expect.equal 1
              )
                |> Test.test "Horizontal Ellipsis"
            , (\_ ->
                P.getCharWidth '▸'
                    |> Expect.equal 1
              )
                |> Test.test "Black Right-Pointing Small Triangle"
            , (\_ ->
                P.getCharWidth '▾'
                    |> Expect.equal 1
              )
                |> Test.test "Black Down-Pointing Small Triangle"
            , (\_ ->
                P.getCharWidth '▼'
                    |> Expect.equal 1
              )
                |> Test.test "Black Down-Pointing Triangle"
            , (\_ ->
                P.getCharWidth '❤'
                    |> Expect.equal 1
              )
                |> Test.test "Heavy Black Heart"
            , (\_ ->
                P.getCharWidth '█'
                    |> Expect.equal 1
              )
                |> Test.test "Full Block"
            , (\_ ->
                P.getCharWidth '░'
                    |> Expect.equal 1
              )
                |> Test.test "Light Shade"
            , (\_ ->
                P.getCharWidth '✗'
                    |> Expect.equal 1
              )
                |> Test.test "Ballot X"
            , (\_ ->
                P.getCharWidth '✓'
                    |> Expect.equal 1
              )
                |> Test.test "Check Mark"
            , (\_ ->
                P.getCharWidth '—'
                    |> Expect.equal 1
              )
                |> Test.test "Em Dash"
            , (\_ ->
                P.getCharWidth '🌈'
                    |> Expect.equal 2
              )
                |> Test.test "Rainbow"
            , (\_ ->
                P.getCharWidth '🔥'
                    |> Expect.equal 2
              )
                |> Test.test "Fire"
            ]
        ]
