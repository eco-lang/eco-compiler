module Compiler.Lexer.PrimitivesTest exposing (suite)

{-| Tests for `Compiler.Lexer.Primitives.codePointAt`, the code point of the
character at a position of an Elm string and the number of UTF-16 code units it
occupies.

The parser's positions are indexes into the source string counted in UTF-16
code units, and scanners such as the line-comment scanner in
`Compiler.Parse.Space` step past a character by adding its width to the
position. A character outside the Basic Multilingual Plane (code point above
U+FFFF) takes two code units, so a width of 1 for it would leave the position
in the middle of the character.

The fixture is a short string, a position, an end and the code the host's
`String.uncons` gives for the character there, one per test.

What the tests establish:

  - A BMP character is itself, width 1.
  - A surrogate pair is the joined code point, width 2, both as a host that
    joins it in `String.uncons` gives it and as one that does not.
  - A pair that the end cuts in two is its high surrogate, width 1.
  - A lone high surrogate is itself, width 1.

Among what is not tested:

  - The characters at the boundary, U+FFFF and U+10000.
  - How any scanner uses the width to advance its position.

-}

import Compiler.Lexer.Primitives as P
import Expect
import Test exposing (Test)


{-| The test tree for `Compiler.Lexer.Primitives`, holding the `codePointAt`
tests.
-}
suite : Test
suite =
    Test.describe "Parse.Primitives"
        [ Test.describe "codePointAt"
            [ (\_ ->
                P.codePointAt "aé" 1 2 0xE9
                    |> Expect.equal ( 0xE9, 1 )
              )
                |> Test.test "a BMP character is itself, width 1"
            , (\_ ->
                P.codePointAt "🔥" 0 2 0x0001F525
                    |> Expect.equal ( 0x0001F525, 2 )
              )
                |> Test.test "a joined pair (as String.uncons gives it) is width 2"
            , (\_ ->
                P.codePointAt "🔥" 0 2 0xD83D
                    |> Expect.equal ( 0x0001F525, 2 )
              )
                |> Test.test "a high surrogate given alone is joined with its low surrogate"
            , (\_ ->
                P.codePointAt "🔥" 0 1 0xD83D
                    |> Expect.equal ( 0xD83D, 1 )
              )
                |> Test.test "a high surrogate is not joined across the end"
            , (\_ ->
                P.codePointAt "🔥" 0 1 0x0001F525
                    |> Expect.equal ( 0xD83D, 1 )
              )
                |> Test.test "a joined pair cut by the end is its high surrogate, width 1"
            , (\_ ->
                P.codePointAt "\u{D800}x" 0 2 0xD800
                    |> Expect.equal ( 0xD800, 1 )
              )
                |> Test.test "a lone high surrogate is itself, width 1"
            ]
        ]
