module Parse.StringTests exposing (suite)

{-| Tests for how a `\u{...}` escape in a string literal comes out of the
parser. `Compiler.Parse.String.string` keeps a literal in its escaped source
form rather than decoding it, and it rewrites each `\u{...}` escape as one or
two four-digit `\uXXXX` escapes, as `Compiler.Elm.String.fromChunks` writes
them. These tests pin the exact text that rewriting produces for four escapes.

Each test parses a complete single-line string literal, quotes included, and
compares the result with `Ok` of the expected text and `False`, the flag that
says the literal is not multi-line.

  - `\u{1F648}`, a code point above U+FFFF, becomes the surrogate pair
    `\uD83D\uDE48`.
  - `\u{0001}` becomes `\u0001`.
  - `\u{FFFF}`, the last code point of the Basic Multilingual Plane, becomes
    the single escape `\uFFFF`.
  - `\u{10000}`, the first code point above U+FFFF, becomes `\uD800\uDC00`.

Character literals (`Compiler.Parse.String.character`) hold exactly one
character, which may be one above U+FFFF, two UTF-16 units in the source
(eco 0.2.0 rejected `'😀'`; eco-bugs.md number 9, plans/kg-reported-bugs.md
step 3):

  - `'😀'` is accepted and keeps its source text;
  - `'\u{1F600}'` becomes the surrogate pair escape `\uD83D\uDE00`;
  - `'ab'` and `'😀😀'` hold two characters and are rejected.

Among what is not tested: multi-line literals, the other escapes, malformed or
out-of-range `\u{...}` escapes and the errors they produce, and literals with
any text around the escape.

-}

import Compiler.Parse.Primitives as P
import Compiler.Parse.String as S
import Expect
import Test exposing (Test)


{-| The tests for `\u{...}` escapes in single-line string literals.
-}
suite : Test
suite =
    Test.describe "Parse.String"
        [ Test.describe "singleString"
            [ (\_ ->
                singleString "\"\\u{1F648}\""
                    |> Expect.equal (Ok ( "\\uD83D\\uDE48", False ))
              )
                |> Test.test "🙈"
            , (\_ ->
                singleString "\"\\u{0001}\""
                    |> Expect.equal (Ok ( "\\u0001", False ))
              )
                |> Test.test "\\u{0001}"
            , (\_ ->
                singleString "\"\\u{FFFF}\""
                    |> Expect.equal (Ok ( "\\uFFFF", False ))
              )
                |> Test.test "\\u{FFFF}"
            , (\_ ->
                singleString "\"\\u{10000}\""
                    |> Expect.equal (Ok ( "\\uD800\\uDC00", False ))
              )
                |> Test.test "\\u{10000}"
            ]
        , Test.describe "character"
            [ (\_ ->
                character "'😀'"
                    |> Expect.equal (Ok "😀")
              )
                |> Test.test "'😀'"
            , (\_ ->
                character "'\\u{1F600}'"
                    |> Expect.equal (Ok "\\uD83D\\uDE00")
              )
                |> Test.test "'\\u{1F600}'"
            , (\_ ->
                character "'a'"
                    |> Expect.equal (Ok "a")
              )
                |> Test.test "'a'"
            , (\_ ->
                character "'ab'"
                    |> Expect.equal (Err ())
              )
                |> Test.test "'ab'"
            , (\_ ->
                character "'😀😀'"
                    |> Expect.equal (Err ())
              )
                |> Test.test "'😀😀'"
            ]
        ]


{-| Parses the given text as one complete string literal, returning its
escaped text and the multi-line flag, or `Err ()` if it fails to parse or
leaves input unconsumed.
-}
singleString : String -> Result () ( String, Bool )
singleString =
    P.fromByteString (S.string (\_ _ -> ()) (\_ _ _ -> ())) (\_ _ -> ())


{-| Parses the given text as one complete character literal, returning its
escaped text, or `Err ()` if it fails to parse or leaves input unconsumed.
-}
character : String -> Result () String
character =
    P.fromByteString (S.character (\_ _ -> ()) (\_ _ _ -> ())) (\_ _ -> ())
