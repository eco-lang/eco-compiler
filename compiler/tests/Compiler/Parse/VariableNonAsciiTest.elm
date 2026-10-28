module Compiler.Parse.VariableNonAsciiTest exposing (suite)

{-| Pins the non-ASCII branches of the identifier scanners in
`Compiler.Parse.Variable` (`getLowerWidthHelp`, `getUpperWidthHelp`,
`getInnerWidthHelp`). They once decoded a character 0xC0-0xF7 together with the
following characters as if they were UTF-8 continuation bytes (read with
`P.unsafeIndex`, ignoring `end`) and then applied elm/core's ASCII-only
`Char.isLower`. They now classify the code point with `Compiler.Parse.Unicode`,
as upstream Elm does. Pinned here:

  - `café` is one identifier (upstream Elm accepts Unicode letters);
  - `xÃ$` is not one identifier containing `$`;
  - an `é` at the end of the input is read as a letter, not a crash in
    `unsafeIndex`.

More cases are in `Compiler.Parse.VariableUnicodeExtraTest`.

-}

import Compiler.Parse.Primitives as P
import Compiler.Parse.Variable as Var
import Expect
import Test exposing (Test)


parseLower : String -> Result String String
parseLower src =
    P.fromByteString (Var.lower (\_ _ -> "not lower")) (\r c -> "bad end at " ++ String.fromInt r ++ ":" ++ String.fromInt c) src


suite : Test
suite =
    Test.describe "Variable non-ASCII identifiers"
        [ Test.test "x followed by A-tilde and $ is not one identifier" <|
            \_ ->
                parseLower "xÃ$"
                    |> Expect.notEqual (Ok "xÃ$")
        , Test.test "café is one lower-case identifier" <|
            \_ ->
                parseLower "café"
                    |> Expect.equal (Ok "café")
        , Test.test "a lone é at the end of input gives an error, not a crash" <|
            \_ ->
                case parseLower "é" of
                    Err _ ->
                        Expect.pass

                    Ok name ->
                        Expect.equal "é" name
        ]
