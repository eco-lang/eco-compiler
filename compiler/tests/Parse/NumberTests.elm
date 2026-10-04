module Parse.NumberTests exposing (suite)

{-| Tests for `Compiler.Parse.Number.number`, the parser for Elm numeric
literals. They pin, for a few literals of each kind, the value the parser reads
and the source text it keeps beside it, and the error it gives for a few
literals Elm does not allow, such as ones containing an underscore.

Each test hands one literal, as the whole input, to `singleNumber` and compares
the result. A successful result carries the value and the literal's source text.
A failure carries only the `E.Number` error: its row and column are discarded,
and `singleNumber` also reports input left over after the literal, and input
the parser does not take as a number, as `NumberEnd`.

What the tests establish:

  - Int: `1000`, `42` and `0` read as `Int` with that value and the literal as
    its source text.
  - Float: `1000.42`, `6.022e23`, `6000.022e+36` and `3.14` read as `Float`
    with that value and the literal as its source text. `6000.022e+36` checks a
    signed exponent and a value of `6.000022e39`.
  - Hexadecimal: `0xDEADBEEF`, `0x002B` and `0xFF` read as `Int` 3735928559,
    43 and 255, with the literal, `0x` included, as source text.
  - Invalid numbers: `1_000`, `111_000.602`, `1000.4_205` and `0b1010` fail
    with `NumberEnd`, and `0xDE_AD_BE_EF` fails with `NumberHexDigit`. Because
    left-over input is also reported as `NumberEnd`, the four `NumberEnd` tests
    would pass equally if the parser stopped before the `_` or the `b` and
    succeeded.

Among what is not tested: lower-case hexadecimal digits, a leading zero
(`NumberNoLeadingZero`), a `.` with no digit after it (`NumberDot`), an
exponent with no digits, literals too large for an `Int`, where an error is
reported, and `precedence`.

-}

import Compiler.Parse.Number as N
import Compiler.Parse.Primitives as P
import Compiler.Reporting.Error.Syntax as E
import Expect
import Test exposing (Test)


{-| The number parser tests, in four groups: integer, float, hexadecimal and
invalid literals.
-}
suite : Test
suite =
    Test.describe "Parse.Number"
        [ Test.describe "Int"
            [ (\_ ->
                singleNumber "1000"
                    |> Expect.equal (Ok (N.Int 1000 "1000"))
              )
                |> Test.test "Int with no underscores 1000"
            , (\_ ->
                singleNumber "42"
                    |> Expect.equal (Ok (N.Int 42 "42"))
              )
                |> Test.test "Simple int 42"
            , (\_ ->
                singleNumber "0"
                    |> Expect.equal (Ok (N.Int 0 "0"))
              )
                |> Test.test "Zero"
            ]
        , Test.describe "Float"
            [ (\_ ->
                singleNumber "1000.42"
                    |> Expect.equal (Ok (N.Float 1000.42 "1000.42"))
              )
                |> Test.test "Simple Float with no underscores 1000.42"
            , (\_ ->
                singleNumber "6.022e23"
                    |> Expect.equal (Ok (N.Float 6.022e23 "6.022e23"))
              )
                |> Test.test "Float with exponent and no underscores 6.022e23"
            , (\_ ->
                singleNumber "6000.022e+36"
                    |> Expect.equal (Ok (N.Float 6.000022e39 "6000.022e+36"))
              )
                |> Test.test "Float with exponent and +/- and no underscores 6000.022e+36"
            , (\_ ->
                singleNumber "3.14"
                    |> Expect.equal (Ok (N.Float 3.14 "3.14"))
              )
                |> Test.test "Pi approximation 3.14"
            ]
        , Test.describe "Hexadecimal"
            [ (\_ ->
                singleNumber "0xDEADBEEF"
                    |> Expect.equal (Ok (N.Int 3735928559 "0xDEADBEEF"))
              )
                |> Test.test "0xDEADBEEF"
            , (\_ ->
                singleNumber "0x002B"
                    |> Expect.equal (Ok (N.Int 43 "0x002B"))
              )
                |> Test.test "0x002B"
            , (\_ ->
                singleNumber "0xFF"
                    |> Expect.equal (Ok (N.Int 255 "0xFF"))
              )
                |> Test.test "0xFF"
            ]
        , Test.describe "Invalid numbers"
            [ (\_ ->
                singleNumber "1_000"
                    |> Expect.equal (Err E.NumberEnd)
              )
                |> Test.test "Underscores not allowed in integers 1_000"
            , (\_ ->
                singleNumber "111_000.602"
                    |> Expect.equal (Err E.NumberEnd)
              )
                |> Test.test "Underscores not allowed before decimal point 111_000.602"
            , (\_ ->
                singleNumber "1000.4_205"
                    |> Expect.equal (Err E.NumberEnd)
              )
                |> Test.test "Underscores not allowed after decimal point 1000.4_205"
            , (\_ ->
                singleNumber "0xDE_AD_BE_EF"
                    |> Expect.equal (Err E.NumberHexDigit)
              )
                |> Test.test "Underscores not allowed in hex 0xDE_AD_BE_EF"
            , (\_ ->
                singleNumber "0b1010"
                    |> Expect.equal (Err E.NumberEnd)
              )
                |> Test.test "Binary literals not supported 0b1010"
            ]
        ]


{-| Runs `number` over the whole of the given source and returns the literal it
reads, or the error.

Three failures besides the parser's own `E.Number` error are reported as
`NumberEnd`: input that does not start with a digit, a float that
`String.toFloat` rejects, and text left after the literal. The row and column
of every error are dropped.

-}
singleNumber : String -> Result E.Number N.Number
singleNumber =
    P.fromByteString (N.number (\_ _ -> E.NumberEnd) (\x _ _ -> x)) (\_ _ -> E.NumberEnd)
