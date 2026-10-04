module Parse.PrimitivesTests exposing (suite)

{-| Tests for `Compiler.Parse.Primitives.getCharWidth`, the number of UTF-16
code units a character occupies in an Elm string.

The parser's positions are indexes into the source string counted in UTF-16
code units, and scanners such as the line-comment scanner in
`Compiler.Parse.Space` step past a character by adding its `getCharWidth` to the
position. A character outside the Basic Multilingual Plane (code point above
U+FFFF) takes two code units, so a width of 1 for it would leave the position
in the middle of the character. These tests pin the width for a few characters
on each side of that line.

The fixture is a set of single `Char` literals, one per test.

What the tests establish:

  - `a` (U+0061) and `Z` (U+005A) each have width 1.
  - Ten non-ASCII characters inside the Basic Multilingual Plane each have
    width 1: the horizontal ellipsis (U+2026), the em dash (U+2014), three
    black triangles (U+25B8, U+25BE, U+25BC), the heavy black heart (U+2764),
    the full block (U+2588), the light shade (U+2591), the ballot X (U+2717)
    and the check mark (U+2713).
  - The rainbow emoji (U+1F308) and the fire emoji (U+1F525) each have width 2.

Among what is not tested:

  - The characters at the boundary, U+FFFF and U+10000.
  - How any scanner uses the width to advance its position.

-}

import Compiler.Parse.Primitives as P
import Expect
import Test exposing (Test)


{-| The test tree for `Compiler.Parse.Primitives`, holding one test per
character under `getCharWidth`.
-}
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
