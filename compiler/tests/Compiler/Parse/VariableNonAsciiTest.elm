module Compiler.Parse.VariableNonAsciiTest exposing (suite)

{-| Reproduces a bug in `Compiler.Parse.Variable`: the non-ASCII branches of
the identifier scanners (`getLowerWidthHelp`, `getUpperWidthHelp`,
`getInnerWidthHelp` with `chr2`/`chr3`/`chr4`) were ported from a UTF-8 byte
scanner and are applied to UTF-16 Elm strings. A character 0xC0-0xF7 is decoded
together with the following characters as if they were continuation bytes
(read with `P.unsafeIndex`, ignoring `end`). Consequences pinned here:

  - `café` is not read as one identifier (upstream Elm accepts Unicode letters);
  - `xÃ$` is accepted as ONE identifier containing `$`;
  - an `é` among the last characters of the input crashes via unsafeIndex
    instead of giving a parse error.

EXPECTED TO FAIL until the bug is fixed.

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
                parseLower "x\u{00C3}$"
                    |> Expect.notEqual (Ok "x\u{00C3}$")
        , Test.test "café is one lower-case identifier" <|
            \_ ->
                parseLower "caf\u{00E9}"
                    |> Expect.equal (Ok "caf\u{00E9}")
        , Test.test "a lone é at the end of input gives an error, not a crash" <|
            \_ ->
                case parseLower "\u{00E9}" of
                    Err _ ->
                        Expect.pass

                    Ok name ->
                        Expect.equal "\u{00E9}" name
        ]
